local NS = ...
check(type(NS.L) == "table", "locale table loaded")
eq(NS.L["Not a key"], "Not a key", "locale falls back to key")
check(LibStub ~= nil, "LibStub present")
eq(NS.L["X"], "X", "declared keys return the English text, not true")
