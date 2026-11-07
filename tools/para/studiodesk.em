# studiodesk.em: the whole of Para Studio as an event model, as far as the code goes today. Read top to bottom.
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
screen ChatPanel    | queries ChatSince | commands StartTurn,PickProducer,PickSpeed,NewChat,OpenChat,DeleteChat
screen PlayPanel    | commands StartPlay,TakeShot                                         # the game window: Play, and a picture of it
screen StepsPanel   | queries DeskNow   | commands StartStep                             # Check and Save
screen ResumePanel                                                                       # "Where we left off": read from the game's files
screen BackupSheet  | commands StartStep                                                  # Back up online
screen NewGameSheet | commands NewGame                                                    # Start a game
screen TurnThread   | commands AddLine,EndTurn,RestoreChat
screen JobThread    | commands EndStep

# --- the stories, one line each ---
slice send a message     : ChatPanel -> StartTurn -> TurnStarted -> Desk -> ChatSince -> ChatPanel
slice the producer talks : TurnThread -> AddLine -> LineAdded -> Chat -> ChatSince -> ChatPanel
slice the turn ends      : TurnThread -> EndTurn -> TurnEnded -> Desk -> ChatSince -> ChatPanel
slice run a step         : StepsPanel -> StartStep -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice back up online     : BackupSheet -> StartStep -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice a step ends        : JobThread -> EndStep -> StepEnded -> Desk -> DeskNow -> StepsPanel
slice pick a producer    : ChatPanel -> PickProducer -> AgentPicked -> Desk -> StartTurn
slice pick the first one : SetupPanel -> PickProducer -> AgentPicked -> Desk -> StartTurn
slice pick a speed       : ChatPanel -> PickSpeed -> SpeedPicked -> Desk -> StartTurn
slice delete a chat      : ChatPanel -> DeleteChat -> ChatForgotten -> Chat -> ChatSince -> ChatPanel
slice open a chat again  : TurnThread -> RestoreChat -> ChatRestored -> Chat -> ChatSince -> ChatPanel
slice start a game       : NewGameSheet -> NewGame -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice land a helper's work : GamesPanel -> LandLane -> StepStarted -> Desk -> DeskNow -> StepsPanel
slice press play         : PlayPanel -> StartPlay -> PlayStarted -> Desk
slice take a picture     : PlayPanel -> TakeShot -> ShotAsked -> Desk

# --- requests ---
command StartTurn   game:string agent:string chat:int text:string busyGames:list[string] | reads Chat,Desk | produces LineAdded,TurnStarted | refuses badMessage,busy,tooBusy
command EndTurn     game:string agent:string chat:int turn:int outcome:string | reads Desk | produces TurnEnded | refuses staleTurn
command AddLine     game:string agent:string chat:int line:LineBody | reads Chat | produces LineAdded
command StartStep   game:string kind:string message:string | reads Desk | produces StepStarted | refuses badMessage,busy,needsMessage
command NewGame     name:string existing:list[string] | reads Desk | produces StepStarted | refuses badName,busy,needsName,taken
command LandLane    game:string lane:string lanes:list[string] | reads Desk | produces StepStarted | refuses busy,noSuchLane
command StartPlay   game:string hasSource:bool | reads Desk | produces PlayStarted | refuses busy,noSource
command TakeShot    game:string windowGame:string windowRunning:bool | produces ShotAsked | refuses notRunning,otherGame
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
event PlayStarted   game:string run:int
event ShotAsked     game:string

# --- what is remembered ---
view Desk turns:list[GameTurn] last:list[GameTurn] lastTurn:int stepRunning:bool stepId:int stepKind:string stepGame:string lastStepCode:int picks:list[Pick] speeds:list[SpeedPick] playGame:string playRun:int shotGame:string | consumes AgentPicked,PlayStarted,ShotAsked,SpeedPicked,StepEnded,StepStarted,TurnEnded,TurnStarted
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
