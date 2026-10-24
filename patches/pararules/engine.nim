## pararules 1.4.0 engine, patched for paraloop (see engine.diff for the exact
## changes against upstream). paraloop/sim needs a session's behavior to be a
## function of its facts alone, so a run replays identically in another process
## and after snapshot/restore:
##
## - A fact's alpha nodes are collected in a seq (alpha-tree order), not a
##   pointer-keyed HashSet.
## - Joins walk parent matches and alpha facts sorted by (id, attr), not in
##   Table layout order, which depends on insertion/deletion history. Only
##   the parent matches that pass the id shortcut are sorted, and an alpha
##   node drops an id's table once its last fact for that id is retracted.
## - `fireRules` runs queued `then` blocks sorted by (rule add order, match
##   (id, attr)s) and `thenFinally` blocks by rule add order, instead of
##   iterating HashSets of node pointers. `findAll` and
##   `queryAll(session, rule)` yield matches sorted by (id, attr) too, and
##   `find` returns the lowest one.
## - `JoinNode.oldIdAttrs` counts the matches each fact is in instead of being
##   a set, so retracting one of several matches no longer marks the fact new.
## - `idAttrsComparisons` counts the (id, attr) comparisons every one of those
##   sorts makes, so a test can check a join's sort cost without a clock.
## - A memory node indexes its matches by the id its child join compares, so
##   a fact arriving at a join (a right activation) reads that id's parent
##   matches instead of scanning every one: a position write at a 200-entity
##   cap no longer walks 200 matches per join.
## - `joinMatchesVisited` counts the parent matches those right activations
##   examine, so a test can check that cost without a clock.
## - `autoFire` is exported, and `pendingRules`/`resetPending` read and set
##   a session's set triggers and queued `then`/`thenFinally` blocks, for
##   snapshot/restore.
## - `fireRules` copies a leaf node's match table once per node rather than
##   once per queued `then` (O(N^2) per tick; carried over from parasurvivors).
## - A session holds a `SessionContext` by reference: the entity id allocator
##   and the seeded RNG. Every copy of the session shares it, including the one
##   a `then` receives, so a rule can allocate an id or draw a number and a run
##   still replays from its seed (`paraloop/sim` owns the accessors).
## - `matchCount` reads a rule's number of enabled matches by rule name in
##   O(1): a `then` cannot name another rule, so it asks by string, and
##   `queryAll` would copy every match to count them.

import tables, algorithm, sets, sequtils, random

const paraloopEnginePatched* = true

type
  # facts
  Field* = enum
    Identifier, Attribute, Value
  Fact[T] = tuple[id: T, attr: T, value: T]
  TokenKind = enum
    Insert, Retract, Update
  Token[T] = object
    fact: Fact[T]
    case kind: TokenKind
    of Insert, Retract:
      nil
    of Update:
      oldFact: Fact[T]
  IdAttr = tuple[id: int, attr: int]
  IdAttrs = seq[IdAttr]

  # matches
  Vars*[T] = Table[string, T]
  Var* = object
    name*: string
    field: Field
  Match[MatchT] = object
    id: int
    vars: MatchT
    enabled: bool

  # functions
  ThenFn[T, U, MatchT] = proc (session: var Session[T, MatchT], rule: Production[T, U, MatchT], vars: U)
  WrappedThenFn[MatchT] = proc (vars: MatchT)
  ThenFinallyFn[T, U, MatchT] = proc (session: var Session[T, MatchT], rule: Production[T, U, MatchT])
  WrappedThenFinallyFn = proc ()
  ConvertMatchFn[MatchT, U] = proc (vars: MatchT): U
  CondFn[MatchT] = proc (vars: MatchT): bool
  InitMatchFn[MatchT] = proc (ruleName: string): MatchT

  # alpha network
  AlphaNode[T, MatchT] = ref object
    testField: Field
    testValue: T
    facts: Table[int, Table[int, Fact[T]]]
    successors: seq[JoinNode[T, MatchT]]
    children: seq[AlphaNode[T, MatchT]]

  # beta network
  MemoryNodeType = enum
    Partial, Leaf
  MemoryNode[T, MatchT] = ref object
    parent: JoinNode[T, MatchT]
    child: JoinNode[T, MatchT]
    leafNode: MemoryNode[T, MatchT]
    lastMatchId: int
    ruleOrder: int
    matches: Table[IdAttrs, Match[MatchT]]
    matchesById: Table[int, seq[IdAttrs]]
      ## `matches` keys grouped by the id the child join compares (its
      ## `idName`), so a right activation reads one id's matches instead of
      ## scanning all of them. Unused while the child join has no `idName`.
    matchIds: Table[int, IdAttrs]
    condition: Condition[T]
    ruleName: string
    case nodeType: MemoryNodeType
      of Leaf:
        enabledCount: int
          ## Matches whose `condFn` held when they were last (re)computed:
          ## what `queryAll(session, rule)` would return, kept incrementally.
        condFn: CondFn[MatchT]
        thenFn: WrappedThenFn[MatchT]
        thenFinallyFn: WrappedThenFinallyFn
        trigger: bool
      else:
        nil
  JoinNode[T, MatchT] = ref object
    parent: MemoryNode[T, MatchT]
    child: MemoryNode[T, MatchT]
    alphaNode: AlphaNode[T, MatchT]
    condition: Condition[T]
    idName: string
    oldIdAttrs: CountTable[IdAttr]
    disableFastUpdates: bool
    ruleName: string

  # session
  SessionContext* = ref object
    ## State a `then` may use that is not a fact: the next entity id and the
    ## seeded RNG. It lives on the session by reference, so a session copy
    ## (the one `add` hands every `then`) reads and writes the same one.
    lastId*: int
    rng*: Rand
  Condition[T] = object
    nodes: seq[tuple[testField: Field, testValue: T]]
    vars: seq[Var]
    shouldTrigger: bool
  Production*[T, U, MatchT] = object
    name: string
    conditions: seq[Condition[T]]
    convertMatchFn: ConvertMatchFn[MatchT, U]
    condFn: CondFn[MatchT]
    thenFn: ThenFn[T, U, MatchT]
    thenFinallyFn: ThenFinallyFn[T, U, MatchT]
  Session*[T, MatchT] = object
    alphaNode: AlphaNode[T, MatchT]
    leafNodes: ref Table[string, MemoryNode[T, MatchT]]
    idAttrNodes: ref Table[IdAttr, HashSet[ptr AlphaNode[T, MatchT]]]
    insideRule: bool
    thenQueue: ref HashSet[tuple[node: ptr MemoryNode[T, MatchT], idAttrs: IdAttrs]]
    thenFinallyQueue: ref HashSet[ptr MemoryNode[T, MatchT]]
    triggeredNodeIds: ref HashSet[ptr MemoryNode[T, MatchT]]
    autoFire*: bool
    initMatch: InitMatchFn[MatchT]
    context*: SessionContext

var idAttrsComparisons*: int
var joinMatchesVisited*: int

proc cmpIdAttrs(a, b: IdAttrs): int =
  inc idAttrsComparisons
  for i in 0 ..< min(a.len, b.len):
    result = cmp(a[i], b[i])
    if result != 0:
      return
  result = cmp(a.len, b.len)

proc addNode(node: AlphaNode, newNode: AlphaNode): AlphaNode =
  for child in node.children:
    if child.testField == newNode.testField and child.testValue == newNode.testValue:
      return child
  node.children.add(newNode)
  return newNode

proc addNodes[T, MatchT](session: Session[T, MatchT], nodes: seq[tuple[testField: Field, testValue: T]]): AlphaNode[T, MatchT] =
  result = session.alphaNode
  for node in nodes:
    result = result.addNode(AlphaNode[T, MatchT](testField: node.testField, testValue: node.testValue))

proc add*[T, U, MatchT](production: var Production[T, U, MatchT], id: Var or T, attr: T, value: Var or T, then: bool) =
  var condition = Condition[T](shouldTrigger: then)
  for fieldType in [Field.Identifier, Field.Attribute, Field.Value]:
    case fieldType:
      of Field.Identifier:
        when id is T:
          condition.nodes.add((testField: fieldType, testValue: id))
        else:
          var temp = id
          temp.field = fieldType
          condition.vars.add(temp)
      of Field.Attribute:
        condition.nodes.add((testField: fieldType, testValue: attr))
      of Field.Value:
        when value is T:
          condition.nodes.add((testField: fieldType, testValue: value))
        else:
          var temp = value
          temp.field = fieldType
          condition.vars.add(temp)
  production.conditions.add(condition)

proc isAncestor(x, y: JoinNode): bool =
  var node = y
  while node != nil and node.parent != nil:
    if node.parent.parent == x:
      return true
    else:
      node = node.parent.parent
  false

proc add*[T, U, MatchT](session: Session[T, MatchT], production: Production[T, U, MatchT]) =
  var memNodes: seq[MemoryNode[T, MatchT]]
  var joinNodes: seq[JoinNode[T, MatchT]]
  let last = production.conditions.len - 1
  var
    bindings: HashSet[string]
    joinedBindings: HashSet[string]
  for i in 0 .. last:
    var condition = production.conditions[i]
    var leafAlphaNode = session.addNodes(condition.nodes)
    let parentMemNode = if memNodes.len > 0: memNodes[memNodes.len - 1] else: nil
    var joinNode = JoinNode[T, MatchT](parent: parentMemNode, alphaNode: leafAlphaNode, condition: condition, ruleName: production.name)
    for v in condition.vars:
      if bindings.contains(v.name):
        joinedBindings.incl(v.name)
        if v.field == Identifier:
          joinNode.idName = v.name
      else:
        bindings.incl(v.name)
    if parentMemNode != nil:
      parentMemNode.child = joinNode
    leafAlphaNode.successors.add(joinNode)
    # successors must be sorted by ancestry (descendents first) to avoid duplicate rule firings
    leafAlphaNode.successors.sort(proc (x, y: JoinNode[T, MatchT]): int =
      if isAncestor(x, y): 1 else: -1)
    var memNode = MemoryNode[T, MatchT](parent: joinNode, nodeType: if i == last: Leaf else: Partial, condition: condition, ruleName: production.name, lastMatchId: -1, ruleOrder: session.leafNodes.len)
    if memNode.nodeType == Leaf:
      memNode.condFn = production.condFn
      if production.thenFn != nil:
        var sess = session
        sess.insideRule = true
        memNode.thenFn = proc (vars: MatchT) = production.thenFn(sess, production, production.convertMatchFn(vars))
      if production.thenFinallyFn != nil:
        var sess = session
        sess.insideRule = true
        memNode.thenFinallyFn = proc () = production.thenFinallyFn(sess, production)
      if session.leafNodes.hasKey(production.name):
        raise newException(Exception, production.name & " already exists in session")
      session.leafNodes[production.name] = memNode
    memNodes.add(memNode)
    joinNodes.add(joinNode)
    joinNode.child = memNode
  let leafMemNode = memNodes[memNodes.len - 1]
  for node in memNodes:
    node.leafNode = leafMemNode
  for node in joinNodes:
    # disable fast updates for facts whose value is part of a join
    for v in node.condition.vars:
      if v.field == Value and joinedBindings.contains(v.name):
        node.disableFastUpdates = true
        break

proc getVarFromFact[T, MatchT](vars: var MatchT, key: string, fact: T): bool =
  if vars.hasKey(key) and vars[key] != fact:
    return false
  vars[key] = fact
  true

proc getVarsFromFact[T, MatchT](vars: var MatchT, condition: Condition[T], fact: Fact[T]): bool =
  for v in condition.vars:
    case v.field:
      of Identifier:
        if not getVarFromFact(vars, v.name, fact[0]):
          return false
      of Attribute:
        raise newException(Exception, "Attributes can not contain vars: " & $v)
      of Value:
        if not getVarFromFact(vars, v.name, fact[2]):
          return false
  true

proc getIdAttr[T](fact: Fact[T]): IdAttr =
  let
    id = fact.id.slot0
    attr = fact.attr.slot1.ord
  (id, attr)

proc leftActivation[T, MatchT](session: var Session[T, MatchT], node: var MemoryNode[T, MatchT], idAttrs: IdAttrs, vars: MatchT, token: Token[T], isNew: bool)

proc leftActivation[T, MatchT](session: var Session[T, MatchT], node: JoinNode[T, MatchT], idAttrs: IdAttrs, vars: MatchT, token: Token[T], alphaFact: Fact[T]) =
  var newVars = vars
  if getVarsFromFact(newVars, node.condition, alphaFact):
    let idAttr = alphaFact.getIdAttr
    var newIdAttrs = idAttrs
    newIdAttrs.add(idAttr)
    let newToken = Token[T](fact: alphaFact, kind: token.kind)
    let isNew = not node.oldIdAttrs.contains(idAttr)
    session.leftActivation(node.child, newIdAttrs, newVars, newToken, isNew)

proc leftActivation[T, MatchT](session: var Session[T, MatchT], node: JoinNode[T, MatchT], idAttrs: IdAttrs, vars: MatchT, token: Token[T]) =
  # SHORTCUT: if we know the id, only loop over alpha facts with that id
  if node.idName != "":
    let id = vars[node.idName].slot0
    if node.alphaNode.facts.hasKey(id):
      for alphaFact in node.alphaNode.facts[id].values:
        session.leftActivation(node, idAttrs, vars, token, alphaFact)
  else:
    for id in toSeq(node.alphaNode.facts.keys).sorted:
      for alphaFact in node.alphaNode.facts[id].values:
        session.leftActivation(node, idAttrs, vars, token, alphaFact)

proc leftActivation[T, MatchT](session: var Session[T, MatchT], node: var MemoryNode[T, MatchT], idAttrs: IdAttrs, vars: MatchT, token: Token[T], isNew: bool) =
  let idAttr = idAttrs[idAttrs.len-1]
  # if the insert/update fact is new and this condition doesn't have then = false, let the leaf node trigger
  if isNew and (token.kind == Insert or token.kind == Update) and node.condition.shouldTrigger:
    when not defined(release):
      session.triggeredNodeIds[].incl(node.addr)
    node.leafNode.trigger = true
  # add or remove the match
  case token.kind:
  of Insert, Update:
    var wasEnabled = false
    var match =
      if node.matches.hasKey(idAttrs):
        wasEnabled = node.matches[idAttrs].enabled
        node.matches[idAttrs]
      else:
        node.lastMatchId += 1
        node.parent.oldIdAttrs.inc(idAttr)
        if node.nodeType != Leaf and node.child.idName != "":
          node.matchesById.mgetOrPut(vars[node.child.idName].slot0, @[]).add(idAttrs)
        Match[MatchT](id: node.lastMatchId)
    match.vars = vars
    match.enabled = node.nodeType != Leaf or node.condFn == nil or node.condFn(vars)
    if node.nodeType == Leaf:
      node.enabledCount += int(match.enabled) - int(wasEnabled)
    node.matchIds[match.id] = idAttrs
    node.matches[idAttrs] = match
    if node.nodeType == Leaf and node.trigger:
      if node.thenFn != nil:
        session.thenQueue[].incl((node.addr, idAttrs))
      if node.thenFinallyFn != nil:
        session.thenFinallyQueue[].incl(node.addr)
  of Retract:
    if node.nodeType == Leaf and node.matches[idAttrs].enabled:
      dec node.enabledCount
    node.matchIds.del(node.matches[idAttrs].id)
    if node.nodeType != Leaf and node.child.idName != "":
      let id = node.matches[idAttrs].vars[node.child.idName].slot0
      let at = node.matchesById[id].find(idAttrs)
      node.matchesById[id].del(at)
      if node.matchesById[id].len == 0:
        node.matchesById.del(id)
    node.matches.del(idAttrs)
    node.parent.oldIdAttrs.inc(idAttr, -1)
    if node.nodeType == Leaf:
      if node.thenFinallyFn != nil:
        session.thenFinallyQueue[].incl(node.addr)
  # pass the token down the chain
  if node.nodeType != Leaf:
    session.leftActivation(node.child, idAttrs, vars, token)

proc rightActivation[T, MatchT](session: var Session[T, MatchT], node: JoinNode[T, MatchT], idAttr: IdAttr, token: Token[T]) =
  if node.parent == nil: # root node
    var vars = session.initMatch(node.ruleName)
    if getVarsFromFact(vars, node.condition, token.fact):
      session.leftActivation(node.child, @[idAttr], vars, token, true)
  else:
    var keys: seq[IdAttrs]
    if node.idName != "":
      # SHORTCUT: if we know the id, only the parent matches with that id
      keys = node.parent.matchesById.getOrDefault(token.fact.id.slot0)
      joinMatchesVisited += keys.len
    else:
      for idAttrs in node.parent.matches.keys:
        keys.add(idAttrs)
      joinMatchesVisited += keys.len
    keys.sort(cmpIdAttrs)
    for idAttrs in keys:
      var newVars = node.parent.matches[idAttrs].vars
      if getVarsFromFact(newVars, node.condition, token.fact):
        var newIdAttrs = idAttrs
        newIdAttrs.add(idAttr)
        session.leftActivation(node.child, newIdAttrs, newVars, token, true)

proc rightActivation[T, MatchT](session: var Session[T, MatchT], node: var AlphaNode[T, MatchT], token: Token[T]) =
  let idAttr = token.fact.getIdAttr
  case token.kind:
  of Insert:
    if not node.facts.hasKey(idAttr.id):
      node.facts[idAttr.id] = initTable[int, Fact[T]]()
    node.facts[idAttr.id][idAttr.attr] = token.fact
    if not session.idAttrNodes.hasKey(idAttr):
      session.idAttrNodes[idAttr] = initHashSet[ptr AlphaNode[T, MatchT]](initialSize = 4)
    let exists = session.idAttrNodes[idAttr].containsOrIncl(node.addr)
    assert not exists
  of Retract:
    node.facts[idAttr.id].del(idAttr.attr)
    if node.facts[idAttr.id].len == 0:
      node.facts.del(idAttr.id)
    let missing = session.idAttrNodes[idAttr].missingOrExcl(node.addr)
    assert not missing
    if session.idAttrNodes[idAttr].len == 0:
      session.idAttrNodes.del(idAttr)
  of Update:
    assert node.facts[idAttr.id][idAttr.attr] == token.oldFact
    node.facts[idAttr.id][idAttr.attr] = token.fact
  for child in node.successors:
    if token.kind == Update and child.disableFastUpdates:
      session.rightActivation(child, idAttr, Token[T](fact: token.oldFact, kind: Retract))
      session.rightActivation(child, idAttr, Token[T](fact: token.fact, kind: Insert))
    else:
      session.rightActivation(child, idAttr, token)

proc raiseRecursionLimit(limit: int, additionalText: string = "") =
  let msg = "Recursion limit hit. The current limit is " & $limit & " (set by the recursionLimit param of fireRules)."
  raise newException(Exception, msg & additionalText & "\nTry using `then = false` to prevent triggering rules in an infinite loop.")

when not defined(release):
  import json
  from strutils import nil

  proc raiseRecursionLimit[T, MatchT](limit: int, executedNodes: seq[Table[ptr MemoryNode[T, MatchT], HashSet[ptr MemoryNode[T, MatchT]]]]) =
    var nodes = newJObject()
    for i in countDown(executedNodes.len-1, 0):
      var currNodes = newJObject()
      let nodeToTriggeredNodes = executedNodes[i]
      for (node, triggeredNodes) in nodeToTriggeredNodes.pairs:
        var obj = newJObject()
        for triggeredNode in triggeredNodes:
          if triggeredNode.ruleName in nodes:
            obj[triggeredNode.ruleName] = nodes[triggeredNode.ruleName]
        currNodes[node.ruleName] = obj
      nodes = currNodes
    proc findCycles(cycles: var HashSet[seq[string]], k: string, v: JsonNode, cyc: seq[string]) =
      var newCyc = cyc
      newCyc.add k
      let index = cyc.find(k)
      if index >= 0:
        cycles.incl newCyc[index ..< newCyc.len]
      else:
        for pair in v.pairs:
          findCycles(cycles, pair.key, pair.val, newCyc)
    var cycles: HashSet[seq[string]]
    for pair in nodes.pairs:
      findCycles(cycles, pair.key, pair.val, @[])
    var text = ""
    for cycle in cycles:
      text &= "\nCycle detected! "
      if cycle.len == 2:
        text &= cycle[0] & " is triggering itself."
      else:
        text &= strutils.join(cycle, " -> ")
    raiseRecursionLimit(limit, text)

proc fireRules*[T, MatchT](session: var Session[T, MatchT], recursionLimit: int = 16) =
  if session.insideRule:
    return
  when not defined(release):
    var executedNodes: seq[Table[ptr MemoryNode[T, MatchT], HashSet[ptr MemoryNode[T, MatchT]]]]
  var recurCount = 0
  while true:
    if recursionLimit >= 0:
      if recurCount == recursionLimit:
        when defined(release):
          raiseRecursionLimit(recursionLimit)
        else:
          raiseRecursionLimit(recursionLimit, executedNodes)
      recurCount += 1
    var thenQueue = session.thenQueue[].toSeq
    var thenFinallyQueue = session.thenFinallyQueue[].toSeq
    if thenQueue.len == 0 and thenFinallyQueue.len == 0:
      return
    thenQueue.sort(proc (a, b: tuple[node: ptr MemoryNode[T, MatchT], idAttrs: IdAttrs]): int =
      result = cmp(a.node.ruleOrder, b.node.ruleOrder)
      if result == 0:
        result = cmpIdAttrs(a.idAttrs, b.idAttrs))
    thenFinallyQueue.sort(proc (a, b: ptr MemoryNode[T, MatchT]): int = cmp(a.ruleOrder, b.ruleOrder))
    # reset state
    session.thenQueue[].clear
    session.thenFinallyQueue[].clear
    for (node, idAttrs) in thenQueue:
      node.trigger = false
    for node in thenFinallyQueue:
      node.trigger = false
    when not defined(release):
      var nodeToTriggeredNodeIds: Table[ptr MemoryNode[T, MatchT], HashSet[ptr MemoryNode[T, MatchT]]]
      proc add(t: var Table[ptr MemoryNode[T, MatchT], HashSet[ptr MemoryNode[T, MatchT]]], nodeId: ptr MemoryNode[T, MatchT], s: HashSet[ptr MemoryNode[T, MatchT]]) =
        if nodeId notin t:
          t[nodeId] = initHashSet[ptr MemoryNode[T, MatchT]]()
        t[nodeId].incl(s)
    # keep a copy of the matches before executing the :then functions.
    # if we pull the matches from inside the for loop below,
    # it'll produce non-deterministic results because `matches`
    # could be modified by the for loop itself. see test: "non-deterministic behavior"
    var nodeToMatches: Table[ptr MemoryNode[T, MatchT], Table[IdAttrs, Match[MatchT]]]
    for (node, _) in thenQueue:
      if not nodeToMatches.hasKey(node):
        nodeToMatches[node] = node.matches
    # execute `then` blocks
    for (node, idAttrs) in thenQueue:
      if nodeToMatches[node].hasKey(idAttrs):
        let match = nodeToMatches[node][idAttrs]
        if match.enabled:
          when not defined(release):
            session.triggeredNodeIds[].clear
          node.thenFn(match.vars)
          when not defined(release):
            add(nodeToTriggeredNodeIds, node, session.triggeredNodeIds[])
    # execute `thenFinally` blocks
    for node in thenFinallyQueue:
      when not defined(release):
        session.triggeredNodeIds[].clear
      node.thenFinallyFn()
      when not defined(release):
        add(nodeToTriggeredNodeIds, node, session.triggeredNodeIds[])
    when not defined(release):
      # save triggered node ids
      executedNodes.add(nodeToTriggeredNodeIds)

proc getAlphaNodesForFact[T, MatchT](session: var Session[T, MatchT], node: var AlphaNode[T, MatchT], fact: Fact[T], root: bool, nodes: var seq[ptr AlphaNode[T, MatchT]]) =
  if root:
    for child in node.children.mitems:
      session.getAlphaNodesForFact(child, fact, false, nodes)
  else:
    let val = case node.testField:
      of Field.Identifier: fact[0]
      of Field.Attribute: fact[1]
      of Field.Value: fact[2]
    if val != node.testValue:
      return
    nodes.add(node.addr)
    for child in node.children.mitems:
      session.getAlphaNodesForFact(child, fact, false, nodes)

proc upsertFact[T, MatchT](session: var Session[T, MatchT], fact: Fact[T], nodes: seq[ptr AlphaNode[T, MatchT]]) =
  let idAttr = fact.getIdAttr
  if not session.idAttrNodes.hasKey(idAttr):
    for n in nodes:
      session.rightActivation(n[], Token[T](fact: fact, kind: Insert))
  else:
    let existingNodes = session.idAttrNodes[idAttr]
    # retract any facts from nodes that the new fact wasn't inserted in
    # we use toSeq here to make a copy of the existingNodes, because
    # rightActivation will modify it
    for n in existingNodes.items.toSeq:
      if not nodes.contains(n):
        let oldFact = n.facts[fact.id.slot0][fact.attr.slot1.ord]
        session.rightActivation(n[], Token[T](fact: oldFact, kind: Retract))
    # update or insert facts, depending on whether the node already exists
    for n in nodes:
      if existingNodes.contains(n):
        let oldFact = n.facts[fact.id.slot0][fact.attr.slot1.ord]
        session.rightActivation(n[], Token[T](fact: fact, kind: Update, oldFact: oldFact))
      else:
        session.rightActivation(n[], Token[T](fact: fact, kind: Insert))

proc insertFact*[T, MatchT](session: var Session[T, MatchT], fact: Fact[T]) =
  var nodes: seq[ptr AlphaNode[T, MatchT]]
  getAlphaNodesForFact(session, session.alphaNode, fact, true, nodes)
  session.upsertFact(fact, nodes)
  if session.autoFire:
    session.fireRules()

proc retractFact*[T, MatchT](session: var Session[T, MatchT], fact: Fact[T]) =
  let idAttr = fact.getIdAttr
  # we use toSeq here to make a copy of idAttrNodes[idAttr], since
  # rightActivation will modify it
  for node in session.idAttrNodes[idAttr].items.toSeq:
    assert fact == node.facts[idAttr.id][idAttr.attr]
    session.rightActivation(node[], Token[T](fact: fact, kind: Retract))

proc retractFact*[T, MatchT](session: var Session[T, MatchT], id: T, attr: T) =
  let id = id.slot0
  let attr = attr.slot1.ord
  retractFact(session, id, attr)

proc retractFact*[T, MatchT](session: var Session[T, MatchT], id: int, attr: int) =
  let idAttr = (id, attr)
  # we use toSeq here to make a copy of idAttrNodes[idAttr], since
  # rightActivation will modify it
  for node in session.idAttrNodes[idAttr].items.toSeq:
    let fact = node.facts[id][attr]
    session.rightActivation(node[], Token[T](fact: fact, kind: Retract))

proc defaultInitMatch[MatchT](ruleName: string): MatchT =
  MatchT()

proc initSession*[T, MatchT](autoFire: bool = true, initMatch: InitMatchFn[MatchT] = defaultInitMatch): Session[T, MatchT] =
  result.alphaNode = new(AlphaNode[T, MatchT])
  result.leafNodes = newTable[string, MemoryNode[T, MatchT]]()
  result.idAttrNodes = newTable[IdAttr, HashSet[ptr AlphaNode[T, MatchT]]]()
  new result.thenQueue
  result.thenQueue[] = initHashSet[(ptr MemoryNode[T, MatchT], IdAttrs)]()
  new result.thenFinallyQueue
  result.thenFinallyQueue[] = initHashSet[ptr MemoryNode[T, MatchT]]()
  when not defined(release):
    new result.triggeredNodeIds
    result.triggeredNodeIds[] = initHashSet[ptr MemoryNode[T, MatchT]]()
  result.autoFire = autoFire
  result.initMatch = initMatch
  result.context = SessionContext(rng: initRand(0))

proc initProduction*[T, U, MatchT](name: string, convertMatchFn: ConvertMatchFn[MatchT, U], condFn: CondFn[MatchT], thenFn: ThenFn[T, U, MatchT], thenFinallyFn: ThenFinallyFn[T, U, MatchT]): Production[T, U, MatchT] =
  result.name = name
  result.convertMatchFn = convertMatchFn
  result.condFn = condFn
  result.thenFn = thenFn
  result.thenFinallyFn = thenFinallyFn

proc sortedMatches[T, MatchT](node: MemoryNode[T, MatchT], keys: seq[IdAttrs]): seq[Match[MatchT]] =
  for idAttrs in keys.sorted(cmpIdAttrs):
    result.add(node.matches[idAttrs])

proc matchesParams[I, T, MatchT](vars: MatchT, params: array[I, (string, T)]): bool =
  for (varName, val) in params:
    if vars[varname] != val:
      return false
  true

proc find*[I, T](session: Session, prod: Production, params: array[I, (string, T)]): int =
  result = -1
  var first: IdAttrs
  for idAttrs, match in session.leafNodes[prod.name].matches.pairs:
    if match.enabled and matchesParams(match.vars, params) and (result == -1 or cmpIdAttrs(idAttrs, first) < 0):
      first = idAttrs
      result = match.id

proc find*(session: Session, prod: Production): int =
  result = -1
  var first: IdAttrs
  for idAttrs, match in session.leafNodes[prod.name].matches.pairs:
    if match.enabled and (result == -1 or cmpIdAttrs(idAttrs, first) < 0):
      first = idAttrs
      result = match.id

proc findAll*[I, T](session: Session, prod: Production, params: array[I, (string, T)]): seq[int] =
  let node = session.leafNodes[prod.name]
  var keys: seq[IdAttrs]
  for idAttrs, match in node.matches.pairs:
    if match.enabled and matchesParams(match.vars, params):
      keys.add(idAttrs)
  for match in node.sortedMatches(keys):
    result.add(match.id)

proc findAll*(session: Session, prod: Production): seq[int] =
  let node = session.leafNodes[prod.name]
  var keys: seq[IdAttrs]
  for idAttrs, match in node.matches.pairs:
    if match.enabled:
      keys.add(idAttrs)
  for match in node.sortedMatches(keys):
    result.add(match.id)

proc queryAll*[T, MatchT](session: Session[T, MatchT]): seq[tuple[id: int, attr: int, value: T]] =
  for idAttr, nodes in session.idAttrNodes.pairs:
    assert nodes.len > 0
    let
      firstNode = nodes.toSeq[0]
      fact = firstNode[].facts[idAttr.id][idAttr.attr]
    result.add((idAttr.id, idAttr.attr, fact.value))

proc queryAll*[T, U, MatchT](session: Session[T, MatchT], prod: Production[T, U, MatchT]): seq[U] =
  let node = session.leafNodes[prod.name]
  var keys: seq[IdAttrs]
  for idAttrs, match in node.matches.pairs:
    if match.enabled:
      keys.add(idAttrs)
  for match in node.sortedMatches(keys):
    result.add(prod.convertMatchFn(match.vars))

proc enabledMatchCount[T, MatchT](session: Session[T, MatchT], ruleName: string): int =
  if not session.leafNodes.hasKey(ruleName):
    raise newException(KeyError, "matchCount: no rule named \"" & ruleName & "\" in this session")
  session.leafNodes[ruleName].enabledCount

proc matchCount*[T, MatchT](session: Session[T, MatchT], ruleName: string): int =
  ## How many matches the rule named `ruleName` has now (the length of
  ## `queryAll(session, rule)`), without building them. Raises `KeyError`
  ## naming the rule when the session has no such rule.
  session.enabledMatchCount(ruleName)

proc matchCount*[T, U, MatchT](session: Session[T, MatchT], prod: Production[T, U, MatchT]): int =
  session.enabledMatchCount(prod.name)

proc get*[T, U, MatchT](session: Session[T, MatchT], prod: Production[T, U, MatchT], i: int): U =
  let idAttrs = session.leafNodes[prod.name].matchIds[i]
  prod.convertMatchFn(session.leafNodes[prod.name].matches[idAttrs].vars)

proc unwrap*(fact: object, kind: type): kind =
  for key, val in fact.fieldPairs:
    when val is kind:
      return val
  raise newException(Exception, "The given object has no field of type " & $kind)

proc contains*[T, MatchT](session: Session[T, MatchT], id: int, attr: int): bool =
  session.idAttrNodes.contains((id, attr))

type
  PendingRules* = object
    ## A session's pending rule work, keyed by rule name and match (id, attr)s
    ## and sorted, so it carries over to another session with the same rules.
    triggers*: seq[string]
    thens*: seq[tuple[rule: string, idAttrs: seq[tuple[id: int, attr: int]]]]
    thenFinallys*: seq[string]

proc pendingRules*[T, MatchT](session: Session[T, MatchT]): PendingRules =
  ## The rules whose trigger is set and the `then`/`thenFinally` blocks
  ## queued for the next `fireRules`. `fireRules` leaves a trigger set when
  ## its rule triggered but had no match to run (the rule then runs on its
  ## next match), and inserts or retracts made after `fireRules` queue
  ## blocks, so all three are session state a snapshot must carry.
  for name, node in session.leafNodes.pairs:
    if node.trigger:
      result.triggers.add(name)
  for (node, idAttrs) in session.thenQueue[].items:
    result.thens.add((node.ruleName, idAttrs))
  for node in session.thenFinallyQueue[].items:
    result.thenFinallys.add(node.ruleName)
  result.triggers.sort()
  result.thens.sort(proc (a, b: tuple[rule: string, idAttrs: IdAttrs]): int =
    result = cmp(a.rule, b.rule)
    if result == 0:
      result = cmpIdAttrs(a.idAttrs, b.idAttrs))
  result.thenFinallys.sort()

proc resetPending*[T, MatchT](session: var Session[T, MatchT], pending: PendingRules) =
  ## Replaces the session's set triggers and queued blocks with exactly
  ## `pending`, as `pendingRules` returned it.
  session.thenQueue[].clear
  session.thenFinallyQueue[].clear
  for name, node in session.leafNodes.pairs:
    node.trigger = name in pending.triggers
  for (rule, idAttrs) in pending.thens:
    session.thenQueue[].incl((session.leafNodes[rule].parent.child.addr, idAttrs))
  for rule in pending.thenFinallys:
    session.thenFinallyQueue[].incl(session.leafNodes[rule].parent.child.addr)
