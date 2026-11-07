# studio-plan.em: Para Studio as it will be once the later slices of the Eversince migration are in.
# NOT checked by the build: nothing compiles against this file. It is the checked file, studiodesk.em,
# plus the blocks and stories the later slices add, so one picture (docs/studio-plan.svg) shows where
# the app is going and the other (docs/studio-model.svg) where it is.
#
# The one rule, held by tests/test_para_studio_model.nim: the plan may be ahead of the code and never
# behind it. Every record, event, command, view, query and processor line of studiodesk.em is here
# with the same canonical line, every one of its slices is here as it is, and every one of its screens
# is here with at least the same commands and queries (a screen may offer more later). So a slice moves
# a block's line from this file into studiodesk.em when the code gets it, in the same change.
#
# `eversince check tools/para/studio-plan.em` without --app must pass with no error; the lints (an event no
# command produces yet, a command on no screen) are expected until the slices land.
#
# Slices 3 to 5 also CHANGE a few checked lines, which this file may not show (it may not disagree
# with the code). They are listed here, as comments, for whoever builds that slice:
#   slice 3  command NewChat   game:string | reads ChatBook,Desk | produces ChatStarted | refuses busy
#            command OpenChat  game:string chat:int | reads ChatBook,Desk | produces ChatOpened | refuses busy,noSuchChat
#            command DeleteChat game:string agent:string chat:int | reads ChatBook,Desk | produces ChatForgotten | refuses busy,noSuchChat
#            view ChatBook consumes ChatForgotten too; the stories "a new chat" and "open another chat" are
#            ChatPanel -> NewChat -> ChatStarted -> ChatBook -> ChatList -> ChatPanel (and OpenChat, ChatOpened)
#   slice 5  command StartPlay game:string hasSource:bool | reads Desk,PlayWindow | produces PlayStarted | refuses busy,noSource
#            command TakeShot  game:string windowGame:string windowRunning:bool | reads PlayWindow | produces ShotAsked | refuses notRunning,otherGame
#            (the window facts then come from the PlayWindow view, not from the route)

# --- what the friend sees: the page's panels, and who else acts (a superset of the checked screens) ---
screen SetupPanel   | commands PickProducer
screen GamesPanel   | queries DeskNow   | commands LandLane
screen ChatPanel    | queries ChatList,ChatSince,ProducerNow | commands StartTurn,StopTurn,PickProducer,PickSpeed,NewChat,OpenChat,DeleteChat
screen PlayPanel    | queries PlayNow | commands StartPlay,StopPlay,TakeShot
screen StepsPanel   | queries DeskNow,JobNow | commands StartStep
screen ResumePanel
screen BackupSheet  | commands StartStep
screen NewGameSheet | commands NewGame
screen TurnThread   | commands AddLine,EndTurn,RestoreChat,ReportSession,ReportModel
screen JobThread    | commands EndStep
screen PlayThread   | commands PlayPhase,EndPlay

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

# --- the stories the later slices add ---
slice the turn runs               : TurnRunner -> AddLine -> LineAdded -> Chat -> ChatSince -> ChatPanel
slice the turn is stopped         : ChatPanel -> StopTurn -> StopRequested -> TurnRunner -> EndTurn -> TurnEnded -> Desk -> ChatSince -> ChatPanel
slice the turn runs out of time   : TurnClock -> EndTurn -> TurnEnded -> Desk -> ChatSince -> ChatPanel
slice the step runs               : StepRunner -> EndStep -> StepEnded -> Desk -> JobNow -> StepsPanel
slice the step runs out of time   : StepClock -> EndStep -> StepEnded -> Desk -> JobNow -> StepsPanel
slice the agent names its session : TurnThread -> ReportSession -> SessionReported -> ChatBook -> ChatList -> ChatPanel
slice the agent says what it ran  : TurnThread -> ReportModel -> ModelReported -> Producers -> ProducerNow -> ChatPanel
slice the window sees Play        : PlayPanel -> StartPlay -> PlayStarted -> PlayWindow -> PlayNow -> PlayPanel
slice the window opens            : PlayThread -> PlayPhase -> PlayPhased -> PlayWindow -> PlayNow -> PlayPanel
slice the window closes           : PlayThread -> EndPlay -> PlayEnded -> PlayWindow -> PlayNow -> PlayPanel
slice stop the game               : PlayPanel -> StopPlay -> PlayStopRequested -> PlayRunner -> EndPlay -> PlayEnded -> PlayWindow -> PlayNow -> PlayPanel

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

# --- requests the later slices add ---
command StopTurn      game:string | reads Desk | produces StopRequested | refuses idle                                                           # slice 4
command ReportSession game:string agent:string chat:int session:string | reads ChatBook | produces SessionReported | refuses badSession          # slice 3
command ReportModel   game:string agent:string speed:string askedModel:string askedEffort:string model:string effort:string | reads Producers | produces ModelReported   # slice 3
command PlayPhase     run:int phase:string message:string | reads PlayWindow | produces PlayPhased | refuses staleRun                              # slice 5
command EndPlay       run:int code:int message:string detail:string | reads PlayWindow | produces PlayEnded | refuses staleRun                    # slice 5
command StopPlay      | reads PlayWindow | produces PlayStopRequested | refuses idle                                                              # slice 5

# --- facts the later slices add ---
event StopRequested     game:string turn:int                                  # slice 4
event ChatStarted       game:string agent:string chat:int at:int              # slice 3
event ChatOpened        game:string agent:string chat:int                     # slice 3
event SessionReported   game:string agent:string chat:int session:string      # slice 3
event ModelReported     game:string agent:string speed:string askedModel:string askedEffort:string model:string effort:string   # slice 3
event PlayPhased        run:int phase:string message:string                   # slice 5
event PlayEnded         run:int code:int message:string detail:string         # slice 5
event PlayStopRequested run:int                                               # slice 5

# --- what is remembered, later ---
view ChatBook books:list[Book] | consumes ChatForgotten,ChatOpened,ChatStarted,LineAdded,SessionReported,TurnStarted   # slice 3
view Producers ran:list[Ran] | consumes ModelReported                                                                  # slice 3
view PlayWindow phase:string game:string run:int code:int message:string detail:string | consumes PlayEnded,PlayPhased,PlayStarted,PlayStopRequested   # slice 5

# --- questions, later ---
query ChatList    game:string agent:string | reads ChatBook | returns ChatListing         # slice 3
query ProducerNow game:string agent:string | reads Desk,Producers | returns Ran           # slice 3
query JobNow      | reads Desk | returns JobFacts                                         # slice 4
query PlayNow     | reads PlayWindow | returns PlayFacts                                 # slice 5

# --- background work, later: the shell's threads, named ---
processor TurnRunner | consumes StopRequested,TurnStarted | issues AddLine,EndTurn,ReportModel,ReportSession   # slice 4
processor TurnClock  | consumes TurnStarted | issues EndTurn                                                   # slice 4
processor StepRunner | consumes StepStarted | issues EndStep                                                   # slice 4
processor StepClock  | consumes StepStarted | issues EndStep                                                   # slice 4
processor PlayRunner | consumes PlayStarted,PlayStopRequested | issues EndPlay,PlayPhase                       # slice 5

# --- value types, later ---
record Book         game:string agent:string current:int next:int chats:list[ChatRecord]
record ChatRecord   id:int title:string started:int updated:int session:string
record ChatListing  agent:string current:int chats:list[ChatRecord]
record Ran          game:string agent:string started:bool speed:string askedModel:string askedEffort:string model:string effort:string
record JobFacts     running:bool step:int kind:string game:string code:int
record PlayFacts    state:string game:string run:int message:string code:string detail:string
