-- Atomically check and consume every token bucket in KEYS, or none of them.
-- ARGV holds capacity, refill-per-second, and cost for each key, in order.
-- Each bucket is a hash: t = stored tokens, u = last update in microseconds.
-- Returns {0} when admitted, {1, wait_ms, short indexes...} when throttled,
-- and {2, index} when a cost exceeds its capacity (callers pre-check this).
local now = redis.call('TIME')
local now_us = tonumber(now[1]) * 1000000 + tonumber(now[2])
local tokens = {}
local short = {}
local wait_ms = 0

for i = 1, #KEYS do
  local capacity = tonumber(ARGV[(i - 1) * 3 + 1])
  local refill = tonumber(ARGV[(i - 1) * 3 + 2])
  local cost = tonumber(ARGV[(i - 1) * 3 + 3])
  if cost > capacity then
    return {2, i - 1}
  end
  local available = capacity
  local state = redis.call('HMGET', KEYS[i], 't', 'u')
  if state[1] and state[2] then
    local elapsed = now_us - tonumber(state[2])
    if elapsed < 0 then
      elapsed = 0
    end
    available = tonumber(state[1]) + elapsed / 1000000 * refill
    if available > capacity then
      available = capacity
    end
  end
  tokens[i] = available
  if available < cost then
    short[#short + 1] = i - 1
    local wait = math.ceil((cost - available) / refill * 1000)
    if wait > wait_ms then
      wait_ms = wait
    end
  end
end

if #short > 0 then
  local result = {1, wait_ms}
  for _, index in ipairs(short) do
    result[#result + 1] = index
  end
  return result
end

for i = 1, #KEYS do
  local capacity = tonumber(ARGV[(i - 1) * 3 + 1])
  local refill = tonumber(ARGV[(i - 1) * 3 + 2])
  local cost = tonumber(ARGV[(i - 1) * 3 + 3])
  -- Format explicitly: Lua's default number-to-string conversion keeps only
  -- 14 significant digits, which would truncate microsecond timestamps.
  redis.call('HSET', KEYS[i], 't', string.format('%.17g', tokens[i] - cost), 'u', string.format('%.0f', now_us))
  redis.call('PEXPIRE', KEYS[i], string.format('%.0f', math.ceil(capacity / refill * 1000) + 1000))
end
return {0}
