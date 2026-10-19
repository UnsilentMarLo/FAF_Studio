local s = EdPopoutInput
if not s then return 'no state' end
local ev = ''
for i = 1, math.min(table.getn(s.events), 12) do ev = ev .. s.events[i] .. ' ' end
return 'events=' .. s.count .. ' [' .. ev .. '] editText=' .. tostring(s.edit:GetText())
