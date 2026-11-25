Fixtures for tests/test_para_purity.nim: the core files (`rules.nim`, `data.nim`, `systems.nim`) of
two games that are never compiled, only scanned by `para check`'s purity step
(tools/para/purity.nim). `pure/` uses everything a core file legitimately may and must pass;
`impure/` has one banned import or `then` call per marked line and must fail on exactly those.
