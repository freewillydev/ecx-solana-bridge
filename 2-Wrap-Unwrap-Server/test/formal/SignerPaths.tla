--------------------------- MODULE SignerPaths ---------------------------
EXTENDS FiniteSets
CONSTANT Requests
ASSUME Requests # {}
Paths == {"sign-preparation", "sign-replacement", "draft-replacement", "checkpoint-custody"}
Operations == {"SignPrepared", "SignReplacement", "DraftReplacement", "CheckpointCustody"}
Constructors == {"PreparedResult", "ReplacementResult", "DraftResult", "CheckpointResult"}
None == "none"
Handler(p) == CASE p = "sign-preparation" -> "SignPrepared"
               [] p = "sign-replacement" -> "SignReplacement"
               [] p = "draft-replacement" -> "DraftReplacement"
               [] p = "checkpoint-custody" -> "CheckpointCustody"
NoCommand == [caller |-> None, severity |-> None, operation |-> None]
Command(op) == [caller |-> "Signer", severity |-> "Critical", operation |-> op]
Result(op) == CASE op = "SignPrepared" -> "PreparedResult"
              [] op = "SignReplacement" -> "ReplacementResult"
              [] op = "DraftReplacement" -> "DraftResult"
              [] op = "CheckpointCustody" -> "CheckpointResult"
Owner(c) == CHOOSE p \in Paths : Result(Handler(p)) = c
VARIABLES stage, path, authenticated, eligible, stable, operation, dsl, output, paying, dispatched
vars == <<stage, path, authenticated, eligible, stable, operation, dsl, output, paying, dispatched>>
Init == /\ stage = [r \in Requests |-> "idle"]
        /\ path = [r \in Requests |-> None]
        /\ authenticated = [r \in Requests |-> FALSE]
        /\ eligible = [r \in Requests |-> FALSE]
        /\ stable = [r \in Requests |-> FALSE]
        /\ operation = [r \in Requests |-> None]
        /\ dsl = [r \in Requests |-> NoCommand]
        /\ output = [r \in Requests |-> None]
        /\ paying = [r \in Requests |-> FALSE]
        /\ dispatched = [r \in Requests |-> FALSE]
Receive(r,p,a,e,s,mode) ==
  /\ stage[r] = "idle"
  /\ stage' = [stage EXCEPT ![r] = "requested"]
  /\ path' = [path EXCEPT ![r] = p]
  /\ authenticated' = [authenticated EXCEPT ![r] = a]
  /\ eligible' = [eligible EXCEPT ![r] = e]
  /\ stable' = [stable EXCEPT ![r] = s]
  /\ paying' = [paying EXCEPT ![r] = mode]
  /\ UNCHANGED <<operation,dsl,output,dispatched>>
\* The enclosing worker workflow already holds its gate. Only its private
\* critical dispatcher can enter this signing-transport branch.
Dispatch(r) ==
  /\ stage[r] = "requested" /\ paying[r]
  /\ stage' = [stage EXCEPT ![r] = "received"]
  /\ dispatched' = [dispatched EXCEPT ![r] = TRUE]
  /\ UNCHANGED <<path,authenticated,eligible,stable,operation,dsl,output,paying>>
Route(r) ==
  /\ stage[r] = "received" /\ authenticated[r] /\ path[r] \in Paths
  /\ stage' = [stage EXCEPT ![r] = "resolved"]
  /\ operation' = [operation EXCEPT ![r] = Handler(path[r])]
  /\ UNCHANGED <<path,authenticated,eligible,stable,dsl,output,paying,dispatched>>
Resolve(r) ==
  /\ stage[r] = "resolved"
  /\ stage' = [stage EXCEPT ![r] = "dsl"]
  /\ dsl' = [dsl EXCEPT ![r] = Command(operation[r])]
  /\ UNCHANGED <<path,authenticated,eligible,stable,operation,output,paying,dispatched>>
\* Runtime operation_path logs use resolved/dsl/evaluating/done/rejected.
\* EnterEvaluator corresponds to acquisition of the signer critical gate;
\* logs themselves are diagnostic, not an additional authorization mechanism.
EnterEvaluator(r) ==
  /\ stage[r] = "dsl"
  /\ stage' = [stage EXCEPT ![r] = "evaluating"]
  /\ UNCHANGED <<path,authenticated,eligible,stable,operation,dsl,output,paying,dispatched>>
Evaluate(r) ==
  /\ stage[r] = "evaluating" /\ eligible[r] /\ stable[r]
  /\ stage' = [stage EXCEPT ![r] = "done"]
  /\ output' = [output EXCEPT ![r] = Result(dsl[r].operation)]
  /\ UNCHANGED <<path,authenticated,eligible,stable,operation,dsl,paying,dispatched>>
Reject(r) ==
  /\ \/ stage[r] = "requested" /\ ~paying[r]
     \/ stage[r] = "received" /\ (~authenticated[r] \/ path[r] \notin Paths)
     \/ stage[r] = "evaluating" /\ (~eligible[r] \/ ~stable[r])
  /\ stage' = [stage EXCEPT ![r] = "rejected"]
  /\ UNCHANGED <<path,authenticated,eligible,stable,operation,dsl,output,paying,dispatched>>
Next == \E r \in Requests :
          (\E p \in Paths \cup {"unknown"}, a,e,s,mode \in BOOLEAN : Receive(r,p,a,e,s,mode))
          \/ Dispatch(r) \/ Route(r) \/ Resolve(r) \/ EnterEvaluator(r) \/ Evaluate(r) \/ Reject(r)
Spec == Init /\ [][Next]_vars
TypeOK ==
  /\ stage \in [Requests -> {"idle","requested","received","resolved","dsl","evaluating","done","rejected"}]
  /\ path \in [Requests -> Paths \cup {None,"unknown"}]
  /\ authenticated \in [Requests -> BOOLEAN]
  /\ eligible \in [Requests -> BOOLEAN] /\ stable \in [Requests -> BOOLEAN]
  /\ operation \in [Requests -> Operations \cup {None}]
  /\ dsl \in [Requests -> {Command(op) : op \in Operations} \cup {NoCommand}]
  /\ output \in [Requests -> Constructors \cup {None}]
  /\ paying \in [Requests -> BOOLEAN] /\ dispatched \in [Requests -> BOOLEAN]
OutputStates == {[constructor |-> c] : c \in Constructors}
GeneratorPaths(state) == {p \in Paths : Result(Handler(p)) = state.constructor}
UniqueConstructor == \A state \in OutputStates : Cardinality(GeneratorPaths(state)) = 1
Alignment == \A r \in Requests :
  /\ (operation[r] # None => authenticated[r] /\ path[r] \in Paths
                              /\ operation[r] = Handler(path[r]))
  /\ (dsl[r] # NoCommand => operation[r] # None /\ dsl[r] = Command(operation[r]))
  /\ (output[r] # None => stage[r] = "done" /\ eligible[r] /\ stable[r]
          /\ dsl[r] # NoCommand /\ output[r] = Result(dsl[r].operation)
          /\ path[r] = Owner(output[r]))
OnlyCriticalDispatch == \A r \in Requests :
  /\ (dispatched[r] => paying[r])
  /\ (stage[r] \in {"received","resolved","dsl","evaluating","done"} => dispatched[r])
  /\ (output[r] # None => dispatched[r])
OnlyDispatcherEnters == [] [\A r \in Requests : dispatched'[r] # dispatched[r] => Dispatch(r)]_vars
OnlyEvaluatorCreates == [] [\A r \in Requests : output'[r] # output[r] =>
  stage[r] = "evaluating" /\ eligible[r] /\ stable[r] /\ Evaluate(r)]_vars
NoOutputOnRefusal == \A r \in Requests : stage[r] = "rejected" => output[r] = None
\* Inductive argument: Init has no operation/DSL/output. Route is the only writer
\* of operation and checks authentication/path. Dispatch is the only entry
\* to the received state and requires paying mode before signer transport. Resolve is the only writer of DSL
\* and calls Command. Evaluate is the only writer of output and checks both saved
\* eligibility and unchanged authorization. Its constructor is Result(operation).
\* Reject and stuttering preserve output. The four cases of Handler/Result are
\* injective, hence Owner(output) is the originating API path in every reachable
\* state. This is an abstract emission property, not unforgeability of JSON/data
\* or a proof about Haskell execution, cryptography, ledger/RPC validity or crashes.
=============================================================================
