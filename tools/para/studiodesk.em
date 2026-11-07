# studiodesk.em: the whole of Para Studio as an event model, as far as the code goes today. Read top to bottom.
# What survives a restart is the chats' books, the producer and speed picks and what a producer last ran
# with: those events are kept in tmp/studio/studio.jsonl (chatstore.nim) and replayed when the studio starts.
# The compiler checks every record/event/command/view/query line against studiodesk.nim.
# Screens and slices exist only here; the compiler checks that they name real blocks and real edges.
# studio-plan.em, beside it, is the same app with the blocks later slices add (see docs/studio-maintainers.md);
# tests/test_para_studio_model.nim holds this file to it, and docs/studio-model.svg is this file drawn.
#
# There is no processor: processors are delivered inside the command call and do no input or output
# here. The shell's threads (the turn thread, the job thread, the clocks) start and end things and
# issue the commands below back; the screens TurnThread and JobThread stand for them. The game
# window's own thread and the Stop buttons are not here yet: they are the plan's, not the code's.

# --- what the friend sees: one screen for each panel of the page, and who else acts ---
screen SetupPanel   | commands PickProducer                                              # the checklist before the first chat
screen GamesPanel   | queries DeskNow   | commands LandLane                              # the sidebar: games, save points, the helpers' work
screen ChatPanel    | queries ChatSince,ChatList,ProducerNow | commands StartTurn,UseChat,PickProducer,PickSpeed,NewChat,OpenChat,DeleteChat
screen PlayPanel    | commands StartPlay,TakeShot                                         # the game window: Play, and a picture of it
screen StepsPanel   | queries DeskNow   | commands StartStep                             # Check and Save
screen ResumePanel                                                                       # "Where we left off": read from the game's files
screen BackupSheet  | commands StartStep                                                  # Back up online
screen NewGameSheet | commands NewGame                                                    # Start a game
screen TurnThread   | commands AddLine,EndTurn,RestoreChat,ReportSession,ReportModel
screen JobThread    | commands EndStep

# --- the stories, one line each ---
slice send a message     : ChatPanel -> StartTurn -> TurnStarted -> Desk -> ChatSince -> ChatPanel
slice a message names its chat : ChatPanel -> UseChat -> ChatUsed -> ChatBook -> ChatList -> ChatPanel
slice the producer talks : TurnThread -> AddLine -> LineAdded -> Chat -> ChatSince -> ChatPanel
slice the turn ends      : TurnThread -> EndTurn -> TurnEnded -> Desk -> ChatSince -> ChatPanel
slice run a step         : StepsPanel -> StartStep -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice back up online     : BackupSheet -> StartStep -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice a step ends        : JobThread -> EndStep -> StepEnded -> Desk -> DeskNow -> StepsPanel
slice pick a producer    : ChatPanel -> PickProducer -> AgentPicked -> Desk -> StartTurn
slice pick the first one : SetupPanel -> PickProducer -> AgentPicked -> Desk -> StartTurn
slice pick a speed       : ChatPanel -> PickSpeed -> SpeedPicked -> Desk -> StartTurn
slice a new chat         : ChatPanel -> NewChat -> ChatStarted -> ChatBook -> ChatList -> ChatPanel
slice open another chat  : ChatPanel -> OpenChat -> ChatOpened -> ChatBook -> ChatList -> ChatPanel
slice the agent names its session : TurnThread -> ReportSession -> SessionReported -> ChatBook -> ChatList -> ChatPanel
slice the agent says what it ran  : TurnThread -> ReportModel -> ModelReported -> Producers -> ProducerNow -> ChatPanel
slice delete a chat      : ChatPanel -> DeleteChat -> ChatForgotten -> Chat -> ChatSince -> ChatPanel
slice delete a chat from the list : ChatPanel -> DeleteChat -> ChatForgotten -> ChatBook -> ChatList -> ChatPanel
slice delete the open chat : ChatPanel -> DeleteChat -> ChatStarted -> ChatBook -> ChatList -> ChatPanel
slice open a chat again  : TurnThread -> RestoreChat -> ChatRestored -> Chat -> ChatSince -> ChatPanel
slice start a game       : NewGameSheet -> NewGame -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice land a helper's work : GamesPanel -> LandLane -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice press play         : PlayPanel -> StartPlay -> PlayStarted -> Desk
slice take a picture     : PlayPanel -> TakeShot -> ShotAsked -> Desk

# --- requests ---
command StartTurn game:string agent:string chat:int text:string busyGames:list[string] | reads Chat,Desk | produces LineAdded,TurnStarted | refuses badMessage,busy,tooBusy
command EndTurn game:string agent:string chat:int turn:int outcome:string | reads Desk | produces TurnEnded | refuses staleTurn
command AddLine game:string agent:string chat:int line:LineBody | reads Chat | produces LineAdded
command StartStep game:string kind:string message:string | reads Desk | produces StepStarted | refuses badMessage,busy,needsMessage
command NewGame name:string existing:list[string] | reads Desk | produces StepStarted | refuses badName,busy,needsName,taken
command LandLane game:string lane:string lanes:list[string] | reads Desk | produces StepStarted | refuses busy,noSuchLane
command StartPlay game:string hasSource:bool | reads Desk | produces PlayStarted | refuses busy,noSource
command TakeShot game:string windowGame:string windowRunning:bool | produces ShotAsked | refuses notRunning,otherGame
command EndStep step:int code:int | reads Desk | produces StepEnded | refuses staleStep
command PickProducer game:string agent:string | reads Desk | produces AgentPicked | refuses busy
command PickSpeed game:string speed:string | reads Desk | produces SpeedPicked | refuses busy
command NewChat game:string agent:Option[string] | reads ChatBook,Desk | produces ChatStarted | refuses busy
command OpenChat game:string chat:int agent:Option[string] | reads ChatBook,Desk | produces ChatOpened | refuses busy
command DeleteChat game:string agent:string chat:int | reads ChatBook,Desk | produces ChatForgotten,ChatStarted | refuses busy
command UseChat game:string agent:string chat:int title:string | produces ChatUsed
command ReportSession game:string agent:string chat:int session:string | reads ChatBook | produces SessionReported | refuses badSession
command ReportModel game:string agent:string speed:string askedModel:string askedEffort:string model:string effort:string | reads Producers | produces ModelReported
command RestoreChat game:string agent:string chat:int lines:list[LineBody] lastN:int persist:bool | reads Chat | produces ChatRestored,LineAdded

# --- facts ---
event TurnStarted game:string agent:string chat:int turn:int
event TurnEnded game:string agent:string chat:int turn:int outcome:string
event LineAdded game:string agent:string chat:int n:int line:LineBody
event ChatRestored game:string agent:string chat:int lastN:int lines:list[LineBody]
event ChatForgotten game:string agent:string chat:int
event StepStarted game:string step:int kind:string
event StepEnded step:int code:int
event AgentPicked game:string agent:string
event SpeedPicked game:string speed:string
event ChatStarted game:string agent:string chat:int at:int
event ChatOpened game:string agent:string chat:int next:int
event ChatUsed game:string agent:string chat:int at:int title:string
event SessionReported game:string agent:string chat:int session:string
event ModelReported game:string agent:string speed:string askedModel:string askedEffort:string model:string effort:string
event PlayStarted game:string run:int
event ShotAsked game:string

# --- what is remembered ---
view Desk turns:list[GameTurn] last:list[GameTurn] lastTurn:int stepRunning:bool stepId:int stepKind:string stepGame:string lastStepCode:int picks:list[Pick] speeds:list[SpeedPick] playGame:string playRun:int shotGame:string | consumes AgentPicked,PlayStarted,ShotAsked,SpeedPicked,StepEnded,StepStarted,TurnEnded,TurnStarted
view Chat lines:list[ChatEntry] last:int counts:list[ChatCount] | consumes ChatForgotten,ChatRestored,LineAdded,TurnEnded
view ChatBook books:list[Book] | consumes ChatForgotten,ChatOpened,ChatStarted,ChatUsed,SessionReported
view Producers ran:list[Ran] | consumes ModelReported

# --- questions ---
query DeskNow game:string | reads Desk | returns DeskFacts
query ChatSince game:string agent:string chat:int since:int | reads Chat,Desk | returns ChatPage
query ChatList game:string agent:string | reads ChatBook | returns ChatListing
query ProducerNow game:string agent:string | reads Producers | returns Ran

# --- value types ---
record LineBody you:bool kind:string text:string id:string role:string status:string tools:int code:string detail:string url:string
record ChatEntry seq:int game:string agent:string chat:int line:LineBody
record ChatCount game:string agent:string chat:int lines:int
record GameTurn game:string turn:int
record Pick game:string agent:string
record SpeedPick game:string speed:string
record ChatRecord id:int title:string started:int updated:int session:string
record Book game:string agent:string current:int next:int chats:list[ChatRecord]
record ChatListing agent:string current:int chats:list[ChatRecord]
record Ran game:string agent:string started:bool speed:string askedModel:string askedEffort:string model:string effort:string
record DeskFacts working:list[string] running:bool turn:int lastTurn:int stepRunning:bool stepId:int stepKind:string stepGame:string stepCode:int
record ChatPage running:bool working:list[string] turn:int next:int entries:list[ChatEntry]
