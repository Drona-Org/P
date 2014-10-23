event REQ_REPLICA:(seqNum:int, idx:int, val:int);
event RESP_REPLICA_COMMIT:int;
event RESP_REPLICA_ABORT:int;
event GLOBAL_ABORT:int;
event GLOBAL_COMMIT:int;
event WRITE_REQ:(client:model, idx:int, val:int);
event WRITE_FAIL;
event WRITE_SUCCESS;
event READ_REQ:(client:model, idx:int);
event READ_FAIL;
event READ_UNAVAILABLE;
event READ_SUCCESS:int;
event Unit;
event Timeout;
event StartTimer:int;
event CancelTimer;
event CancelTimerFailure;
event CancelTimerSuccess;
event MONITOR_WRITE:(idx:int, val:int);
event MONITOR_READ_SUCCESS:(idx:int, val:int);
event MONITOR_READ_UNAVAILABLE:int;

model Timer {
	var target: machine;
	start state Init {
		entry {
			target = payload as machine;
			raise Unit;
		}
		on Unit goto Loop;
	}

	state Loop {
		ignore CancelTimer;
		on StartTimer goto TimerStarted;
	}

	state TimerStarted {
		entry {
			if ($) {
				send target, Timeout;
				raise Unit;
			}
		}
		on Unit goto Loop;
		on CancelTimer goto Loop with {
			if ($) {
				send target, CancelTimerFailure;
				send target, Timeout;
			} else {
				send target, CancelTimerSuccess;
			}		
		};
	}
}

machine Replica {
	var coordinator: machine;
    var data: map[int,int];
	var pendingWriteReq: (seqNum: int, idx: int, val: int);
	var shouldCommit: bool;
	var lastSeqNum: int;

    start state Init {
	    entry {
		  coordinator = payload as machine;
			lastSeqNum = 0;
			raise Unit;
		}
		on Unit goto Loop;
	}

	fun HandleReqReplica() {
				pendingWriteReq = payload as (seqNum:int, idx:int, val:int);
		assert (pendingWriteReq.seqNum > lastSeqNum);
		shouldCommit = ShouldCommitWrite();
		if (shouldCommit) {
			send coordinator, RESP_REPLICA_COMMIT, pendingWriteReq.seqNum;
		} else {
			send coordinator, RESP_REPLICA_ABORT, pendingWriteReq.seqNum;
		}
	}

	fun HandleGlobalAbort() {
		assert (pendingWriteReq.seqNum >= payload);
		if (pendingWriteReq.seqNum == payload) {
			lastSeqNum = payload;
		}
	}

	fun HandleGlobalCommit() {
		assert (pendingWriteReq.seqNum >= payload);
		if (pendingWriteReq.seqNum == payload) {
			data[pendingWriteReq.idx] = pendingWriteReq.val;
			lastSeqNum = payload;
		}
	}

	state Loop {
		on GLOBAL_ABORT do HandleGlobalAbort;
		on GLOBAL_COMMIT do HandleGlobalCommit;
		on REQ_REPLICA do HandleReqReplica;
	}

	model fun ShouldCommitWrite(): bool 
	{
		return $;
	}
}

machine Coordinator {
	var data: map[int,int];
	var replicas: seq[machine];
	var numReplicas: int;
	var i: int;
	var pendingWriteReq: (client: model, idx: int, val: int);
	var replica: machine;
	var currSeqNum:int;
	var timer: model;

	start state Init {
		entry {
			numReplicas = payload as int;
			assert (numReplicas > 0);
			i = 0;
			while (i < numReplicas) {
				replica = new Replica(this);
				replicas += (i, replica);
				i = i + 1;
			}
			currSeqNum = 0;
			timer = new Timer(this);
			raise Unit;
		}
		on Unit goto Loop;
	}

	fun DoRead() {
		if (payload.idx in data) {
			monitor M, MONITOR_READ_SUCCESS, (idx=payload.idx, val=data[payload.idx]);
			send payload.client, READ_SUCCESS, data[payload.idx];
		} else {
			monitor M, MONITOR_READ_UNAVAILABLE, payload.idx;
			send payload.client, READ_UNAVAILABLE;
		}
	}

	fun DoWrite() {
		pendingWriteReq = payload;
		currSeqNum = currSeqNum + 1;
		i = 0;
		while (i < sizeof(replicas)) {
			send replicas[i], REQ_REPLICA, (seqNum=currSeqNum, idx=pendingWriteReq.idx, val=pendingWriteReq.val);
			i = i + 1;
		}
		send timer, StartTimer, 100;
		raise Unit;
	}

	state Loop {
		on WRITE_REQ do DoWrite;
		on Unit goto CountVote;
		on READ_REQ do DoRead;
		ignore RESP_REPLICA_COMMIT, RESP_REPLICA_ABORT;
	}

	fun DoGlobalAbort() {
		i = 0;
		while (i < sizeof(replicas)) {
			send replicas[i], GLOBAL_ABORT, currSeqNum;
			i = i + 1;
		}
		send pendingWriteReq.client, WRITE_FAIL;
	}

	state CountVote {
		entry {
			if (i == 0) {
				while (i < sizeof(replicas)) {
					send replicas[i], GLOBAL_COMMIT, currSeqNum;
					i = i + 1;
				}
				data[pendingWriteReq.idx] = pendingWriteReq.val;
				monitor M, MONITOR_WRITE, (idx=pendingWriteReq.idx, val=pendingWriteReq.val);
				send pendingWriteReq.client, WRITE_SUCCESS;
				send timer, CancelTimer;
				raise Unit;
			}
		}
		defer WRITE_REQ;
		on READ_REQ do DoRead;
		on RESP_REPLICA_COMMIT goto CountVote with {
			if (currSeqNum == payload) {
				i = i - 1;
			}
		};
		on RESP_REPLICA_ABORT do HandleAbort;
		on Timeout goto Loop with {
			DoGlobalAbort();
		};
		on Unit goto WaitForCancelTimerResponse;
	}

	fun HandleAbort() {
		if (currSeqNum == payload) {
			DoGlobalAbort();
			send timer, CancelTimer;
			raise Unit;
		}
	}

	state WaitForCancelTimerResponse {
		defer WRITE_REQ, READ_REQ;
		ignore RESP_REPLICA_COMMIT, RESP_REPLICA_ABORT;
		on Timeout, CancelTimerSuccess goto Loop;
		on CancelTimerFailure goto WaitForTimeout;
	}

	state WaitForTimeout {
		defer WRITE_REQ, READ_REQ;
		ignore RESP_REPLICA_COMMIT, RESP_REPLICA_ABORT;
		on Timeout goto Loop;
	}
}

model Client {
    var coordinator: machine;
    start state Init {
	    entry {
	        coordinator = payload as machine;
			raise Unit;
		}
		on Unit goto DoWrite;
	}
	var idx: int;
	var val: int;
	state DoWrite {
	    entry {
			idx = ChooseIndex();
			val = ChooseValue();
			send coordinator, WRITE_REQ, (client=this, idx=idx, val=val);
		}
		on WRITE_FAIL goto End;
		on WRITE_SUCCESS goto DoRead;
	}

	state DoRead {
	    entry {
			send coordinator, READ_REQ, (client=this, idx=idx);
		}
		on READ_FAIL goto End;
		on READ_SUCCESS goto End;
	}

	state End { }

	fun ChooseIndex(): int
	{
		if ($) {
			return 0;
		} else {
			return 1;
		}
	}

	fun ChooseValue(): int
	{
		if ($) {
			return 0;
		} else {
			return 1;
		}
	}
}

monitor M {
	var data: map[int,int];
	fun DoWrite() {
			data[payload.idx] = payload.val;
	}
	fun CheckReadSuccess() {
		assert(payload.idx in data);
		assert(data[payload.idx] == payload.val);
	}
	fun CheckReadUnavailable() {
		assert(!(payload in data));
	}
	start state Init {
		on MONITOR_WRITE do DoWrite;
		on MONITOR_READ_SUCCESS do CheckReadSuccess;
		on MONITOR_READ_UNAVAILABLE do CheckReadUnavailable;
	}
}

main model TwoPhaseCommit {
    var coordinator: machine;
	var client: model;
    start state Init {
	    entry {
			new M();
	        coordinator = new Coordinator(2);
			client = new Client(coordinator);
			client = new Client(coordinator);
		}
	}
}