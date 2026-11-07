# studiodesk.em: the chat slice of Para Studio as an event model. Read top to bottom.
# The compiler checks every record/event/command/view/query line against studiodesk.nim.
# Screens and slices exist only here; the compiler checks that they name real blocks and real edges.
#
# There is no processor: processors are delivered inside the command call and do no input or output
# here. The shell's threads (the turn thread, the job thread, the clocks) start and end things and
# issue the commands below back; the screens TurnThread and JobThread stand for them.

# --- what the friend sees, and who else acts ---
screen ChatPanel  | queries ChatSince | commands StartTurn,PickProducer,PickSpeed,NewChat,OpenChat,DeleteChat
screen StepsPanel | queries DeskNow   | commands StartStep
screen TurnThread | commands AddLine,EndTurn,RestoreChat
screen JobThread  | commands EndStep

# --- the stories, one line each ---
slice send a message     : ChatPanel -> StartTurn -> TurnStarted -> Desk -> ChatSince -> ChatPanel
slice the producer talks : TurnThread -> AddLine -> LineAdded -> Chat -> ChatSince -> ChatPanel
slice the turn ends      : TurnThread -> EndTurn -> TurnEnded -> Desk -> ChatSince -> ChatPanel
slice run a step         : StepsPanel -> StartStep -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice a step ends        : JobThread -> EndStep -> StepEnded -> Desk -> DeskNow -> StepsPanel
slice pick a producer    : ChatPanel -> PickProducer -> AgentPicked -> Desk -> StartTurn
slice pick a speed       : ChatPanel -> PickSpeed -> SpeedPicked -> Desk -> StartTurn
slice delete a chat      : ChatPanel -> DeleteChat -> ChatForgotten -> Chat -> ChatSince -> ChatPanel
slice open a chat again  : TurnThread -> RestoreChat -> ChatRestored -> Chat -> ChatSince -> ChatPanel

# --- requests ---
command StartTurn   game:string agent:string chat:int text:string busyGames:list[string] | reads Chat,Desk | produces LineAdded,TurnStarted | refuses badMessage,busy,tooBusy
command EndTurn     game:string agent:string chat:int turn:int outcome:string | reads Desk | produces TurnEnded | refuses staleTurn
command AddLine     game:string agent:string chat:int line:LineBody | reads Chat | produces LineAdded
command StartStep   game:string kind:string message:string | reads Desk | produces StepStarted | refuses busy,needsMessage
command EndStep     step:int code:int | reads Desk | produces StepEnded | refuses staleStep
command PickProducer game:string agent:string | reads Desk | produces AgentPicked | refuses busy
command PickSpeed   game:string speed:string | reads Desk | produces SpeedPicked | refuses busy
command NewChat     game:string | reads Desk | refuses busy
command OpenChat    game:string chat:int | reads Desk | refuses busy
command DeleteChat  game:string agent:string chat:int | reads Desk | produces ChatForgotten | refuses busy
command RestoreChat game:string agent:string chat:int lines:list[LineBody] lastN:int persist:bool | reads Chat | produces ChatRestored,LineAdded

# --- facts ---
event TurnStarted   game:string agent:string chat:int turn:int
event TurnEnded     game:string agent:string chat:int turn:int outcome:string
event LineAdded     game:string agent:string chat:int n:int line:LineBody
event ChatRestored  game:string agent:string chat:int lastN:int lines:list[LineBody]
event ChatForgotten game:string agent:string chat:int
event StepStarted   game:string step:int kind:string
event StepEnded     step:int code:int
event AgentPicked   game:string agent:string
event SpeedPicked   game:string speed:string

# --- what is remembered ---
view Desk turns:list[GameTurn] last:list[GameTurn] lastTurn:int stepRunning:bool stepId:int stepKind:string stepGame:string lastStepCode:int picks:list[Pick] speeds:list[SpeedPick] | consumes AgentPicked,SpeedPicked,StepEnded,StepStarted,TurnEnded,TurnStarted
view Chat lines:list[ChatEntry] last:int counts:list[ChatCount] | consumes ChatForgotten,ChatRestored,LineAdded,TurnEnded

# --- questions ---
query DeskNow game:string | reads Desk | returns DeskFacts
query ChatSince game:string agent:string chat:int since:int | reads Chat,Desk | returns ChatPage

# --- value types ---
record LineBody  you:bool kind:string text:string id:string role:string status:string tools:int code:string detail:string url:string
record ChatEntry seq:int game:string agent:string chat:int line:LineBody
record ChatCount game:string agent:string chat:int lines:int
record GameTurn  game:string turn:int
record Pick      game:string agent:string
record SpeedPick game:string speed:string
record DeskFacts working:list[string] running:bool turn:int lastTurn:int stepRunning:bool stepId:int stepKind:string stepGame:string stepCode:int
record ChatPage  running:bool working:list[string] turn:int next:int entries:list[ChatEntry]
