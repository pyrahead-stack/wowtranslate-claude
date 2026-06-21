-- WoWTranslate_API.lua
-- DLL communication via UnitXP interface
-- Handles async translation requests and polling
-- v0.12: Added demand-based polling, FetchCredits

WoWTranslate_API = {}

-- Internal state
local pendingRequests = {}
local dllAvailable = false
local requestCounter = 0
local pollFrame = nil
local activePendingCount = 0

-- Credit tracking (updated from DLL responses)
local creditsRemaining = -1  -- -1 = unknown
local creditsExhausted = false  -- True when we know credits are zero
local lastError = nil
local lastCreditWarningTime = 0  -- For throttling credit warnings

-- Real spend / budget info (Claude backend, your own API key).
-- Populated from the proxy's __WT_STATS__ sentinel response. -1 = unknown/unlimited.
local spendUsd = -1     -- spent this month, USD (float)
local spendCalls = -1   -- real Claude calls this month
local spendInTok = 0
local spendOutTok = 0
local budgetUsd = -1    -- self-imposed monthly budget, -1 = unlimited
local leftUsd = -1      -- budget remaining, -1 = unlimited

-- Cache savings tracking (session-based)
local sessionCacheHits = 0
local sessionCacheChars = 0
local COST_PER_CHAR = 0.003  -- $30 per million = 0.003 cents per char

-- Constants
local POLL_INTERVAL = 0.1  -- Poll every 100ms
local REQUEST_TIMEOUT = 30 -- Timeout requests after 30 seconds

-- ============================================================================
-- LUA 5.0 COMPATIBILITY
-- ============================================================================
-- strsplit is not available in WoW 1.12, implement it
local function strsplit(delimiter, text, limit)
    if not text then return nil end
    if not delimiter or delimiter == "" then return text end

    local result = {}
    local count = 0
    local start = 1
    local delimStart, delimEnd = string.find(text, delimiter, start, true)

    while delimStart do
        count = count + 1
        if limit and count >= limit then
            break
        end
        table.insert(result, string.sub(text, start, delimStart - 1))
        start = delimEnd + 1
        delimStart, delimEnd = string.find(text, delimiter, start, true)
    end

    table.insert(result, string.sub(text, start))
    return unpack(result)
end

-- ============================================================================
-- DLL STATUS FUNCTIONS
-- ============================================================================

-- Check if DLL is loaded and responding
function WoWTranslate_API.CheckDLL()
    if UnitXP then
        local success, result = pcall(function()
            return UnitXP("WoWTranslate", "ping")
        end)
        if success and result == "pong" then
            dllAvailable = true
            return true
        end
    end
    dllAvailable = false
    return false
end

-- Get DLL status
function WoWTranslate_API.IsAvailable()
    return dllAvailable
end

-- ============================================================================
-- CREDIT TRACKING (v0.10+)
-- ============================================================================

-- Get remaining credits from last API response
-- Returns: credits (number, -1 if unknown), formatted string
function WoWTranslate_API.GetCredits()
    return creditsRemaining
end

-- Get credits as formatted string (e.g., "$4.95" or "Unknown")
function WoWTranslate_API.GetCreditsFormatted()
    if creditsRemaining < 0 then
        return "Unknown"
    end
    -- Convert cents to dollars
    local dollars = creditsRemaining / 100
    return string.format("$%.2f", dollars)
end

-- Get last error message
function WoWTranslate_API.GetLastError()
    return lastError
end

-- Check if credits are low (less than $1.00 = 100 cents)
function WoWTranslate_API.IsCreditsLow()
    return creditsRemaining >= 0 and creditsRemaining < 100
end

-- Check if credits are completely exhausted (translation should be skipped)
function WoWTranslate_API.IsCreditsExhausted()
    return creditsExhausted
end

-- Show credit exhausted warning (throttled to once per 60 seconds)
-- Returns true if warning was shown, false if throttled
function WoWTranslate_API.ShowCreditWarningIfNeeded()
    local now = GetTime()
    if now - lastCreditWarningTime >= 60 then
        lastCreditWarningTime = now
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] " .. WoWTranslate_L.MSG_BUDGET_REACHED .. "|r")
        end
        return true
    end
    return false
end

-- Reset credit exhausted state (called when key changes or credits added)
function WoWTranslate_API.ResetCreditState()
    creditsExhausted = false
    creditsRemaining = -1
    lastError = nil
end

-- Track a cache hit (called when translation comes from local cache)
function WoWTranslate_API.TrackCacheHit(charCount)
    sessionCacheHits = sessionCacheHits + 1
    sessionCacheChars = sessionCacheChars + (charCount or 0)
end

-- Get cache savings for this session
function WoWTranslate_API.GetCacheSavings()
    local savingsCents = sessionCacheChars * COST_PER_CHAR
    return sessionCacheHits, sessionCacheChars, savingsCents
end

-- Get cache savings as formatted string
function WoWTranslate_API.GetCacheSavingsFormatted()
    local hits, chars, cents = WoWTranslate_API.GetCacheSavings()
    if hits == 0 then
        return "No cache hits yet"
    end
    local dollars = cents / 100
    return string.format("%d hits, %d chars, $%.2f saved", hits, chars, dollars)
end

-- ============================================================================
-- REAL SPEND / BUDGET (from proxy __WT_STATS__ sentinel)
-- ============================================================================

-- Parse a "WTSTATS;spentusd=..;calls=..;intok=..;outtok=..;budgetusd=..;leftusd=.."
-- payload that the proxy returns in the translation field. Returns true on match.
function WoWTranslate_API.ParseStats(s)
    if not s or string.find(s, "WTSTATS", 1, true) ~= 1 then return false end
    local function num(key)
        local _, _, v = string.find(s, key .. "=(-?[%d%.]+)")
        return v and tonumber(v) or nil
    end
    spendUsd = num("spentusd") or spendUsd
    spendCalls = num("calls") or spendCalls
    spendInTok = num("intok") or spendInTok
    spendOutTok = num("outtok") or spendOutTok
    budgetUsd = num("budgetusd")
    leftUsd = num("leftusd")
    if budgetUsd == nil then budgetUsd = -1 end
    if leftUsd == nil then leftUsd = -1 end
    -- Keep the credit machinery in sync with the real budget so the existing
    -- low/exhausted logic (and translation auto-stop) works against it.
    if budgetUsd >= 0 and leftUsd >= 0 then
        creditsRemaining = math.floor(leftUsd * 100 + 0.5)
        creditsExhausted = (creditsRemaining <= 0)
    end
    return true
end

-- "Spent this month" line, e.g. "$0.0014  -  12 translations"
function WoWTranslate_API.GetSpentFormatted()
    if spendUsd < 0 then return "Unknown" end
    local s = string.format("$%.4f this month", spendUsd)
    if spendCalls and spendCalls >= 0 then
        s = s .. string.format("  -  %d translations", spendCalls)
    end
    return s
end

-- "Budget" line, e.g. "$5.00  ->  $4.99 left" or "unlimited (your own API key)"
function WoWTranslate_API.GetBudgetFormatted()
    if budgetUsd == nil or budgetUsd < 0 then
        return "unlimited (your own API key)"
    end
    local rest = leftUsd >= 0 and leftUsd or 0
    return string.format("$%.2f  ->  $%.4f left", budgetUsd, rest)
end

-- True when a budget is set and less than $1.00 remains.
function WoWTranslate_API.IsBudgetLow()
    return budgetUsd and budgetUsd >= 0 and leftUsd >= 0 and leftUsd < 1.0
end

-- ============================================================================
-- DEMAND-BASED POLLING HELPERS
-- ============================================================================

-- Called when a new request is queued
local function OnRequestQueued()
    activePendingCount = activePendingCount + 1
    if not pollFrame then
        WoWTranslate_API.StartPolling()
    end
end

-- Called when a request completes or times out
local function OnRequestCompleted()
    activePendingCount = activePendingCount - 1
    if activePendingCount <= 0 then
        activePendingCount = 0
        WoWTranslate_API.StopPolling()
    end
end

-- ============================================================================
-- CREDIT FETCH (prime credits on load)
-- ============================================================================

-- Send a lightweight en->en translation to prime the credits value
function WoWTranslate_API.FetchCredits()
    if not dllAvailable then return false end
    if creditsRemaining >= 0 then return true end  -- Already known

    requestCounter = requestCounter + 1
    local requestId = "credits_" .. tostring(requestCounter)

    pendingRequests[requestId] = {
        callback = function(translation, err)
            -- Discard translation; credits captured by poll handler
        end,
        text = "hello",
        timestamp = GetTime()
    }

    local success = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, "hello", "en", "en")
    end)

    if success then
        OnRequestQueued()
    else
        pendingRequests[requestId] = nil
    end
    return true
end

-- Fetch real spend/budget stats from the proxy. Free (no Claude call) — safe to
-- poll while the config window is open. Updates spend/budget via ParseStats.
function WoWTranslate_API.FetchStats()
    if not dllAvailable then return false end

    requestCounter = requestCounter + 1
    local requestId = "stats_" .. tostring(requestCounter)

    pendingRequests[requestId] = {
        callback = function(translation, err)
            if translation then WoWTranslate_API.ParseStats(translation) end
        end,
        text = "__WT_STATS__",
        timestamp = GetTime()
    }

    local success = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, "__WT_STATS__", "en", "en")
    end)

    if success then
        OnRequestQueued()
    else
        pendingRequests[requestId] = nil
    end
    return true
end

-- ============================================================================
-- API KEY MANAGEMENT
-- ============================================================================

-- Set the WoWTranslate API key in the DLL
function WoWTranslate_API.SetKey(apiKey)
    if not dllAvailable then
        return false, "DLL not available"
    end

    -- Reset credit state when key changes
    creditsRemaining = -1
    creditsExhausted = false
    lastError = nil
    lastCreditWarningTime = 0

    local success, result = pcall(function()
        return UnitXP("WoWTranslate", "setkey", apiKey)
    end)

    if success then
        -- DLL returns "ok" on success or "error|message" on failure
        if result == "ok" then
            return true
        elseif result and string.find(result, "error|") then
            local errorMsg = string.sub(result, 7) -- Remove "error|" prefix
            return false, errorMsg
        else
            return true -- Assume success if no error prefix
        end
    else
        return false, result
    end
end

-- ============================================================================
-- TRANSLATION FUNCTIONS
-- ============================================================================

-- Request an async translation
-- callback(translation, error) will be called when complete
function WoWTranslate_API.Translate(text, callback)
    if not dllAvailable then
        if callback then
            callback(nil, "DLL not available")
        end
        return false
    end

    if not text or text == "" then
        if callback then
            callback(nil, "Empty text")
        end
        return false
    end

    -- Generate unique request ID
    requestCounter = requestCounter + 1
    local requestId = tostring(requestCounter)

    -- Store pending request
    pendingRequests[requestId] = {
        callback = callback,
        text = text,
        timestamp = GetTime()
    }

    -- Source is always auto-detected; user only picks the target language.
    local fromLang = "auto"
    local toLang = WoWTranslateDB and WoWTranslateDB.incomingToLang or "en"
    if toLang == "auto" then toLang = "en" end  -- target must be concrete
    -- Append the languages the user understands so the proxy skips them (no call).
    local toField = toLang
    local understood = WoWTranslateDB and WoWTranslateDB.understoodLangs
    if understood then
        local keep = {}
        for code, on in pairs(understood) do
            if on and code ~= "auto" then table.insert(keep, code) end
        end
        if table.getn(keep) > 0 then
            toField = toLang .. ";keep=" .. table.concat(keep, ",")
        end
    end
    local success, err = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, text, fromLang, toField)
    end)

    if not success then
        pendingRequests[requestId] = nil
        if callback then
            callback(nil, "DLL call failed: " .. tostring(err))
        end
        return false
    end

    OnRequestQueued()
    return true, requestId
end

-- ============================================================================
-- POLLING SYSTEM
-- ============================================================================

-- Poll DLL for completed translations
local function PollTranslations()
    if not dllAvailable then return end

    local success, result = pcall(function()
        return UnitXP("WoWTranslate", "poll")
    end)

    if success and result and result ~= "" then
        -- Parse result format from proxy-enabled DLL:
        -- Success: "requestId|translation|credits|"
        -- Error: "requestId||error_message|credits"
        -- Where credits is optional (may be empty)

        local firstPipe = string.find(result, "|", 1, true)
        if firstPipe then
            local requestId = string.sub(result, 1, firstPipe - 1)
            local remainder = string.sub(result, firstPipe + 1)

            -- Find all pipes in remainder
            local pipes = {}
            local searchPos = 1
            while true do
                local pos = string.find(remainder, "|", searchPos, true)
                if pos then
                    table.insert(pipes, pos)
                    searchPos = pos + 1
                else
                    break
                end
            end

            local translation, err, credits

            if table.getn(pipes) >= 2 then
                -- Format: translation|error|credits
                translation = string.sub(remainder, 1, pipes[1] - 1)
                err = string.sub(remainder, pipes[1] + 1, pipes[2] - 1)
                local creditsStr = string.sub(remainder, pipes[2] + 1)
                credits = tonumber(creditsStr)
            elseif table.getn(pipes) == 1 then
                -- Old format: translation|error
                translation = string.sub(remainder, 1, pipes[1] - 1)
                err = string.sub(remainder, pipes[1] + 1)
            else
                translation = remainder
                err = ""
            end

            -- Update credits if we got a value
            if credits and credits >= 0 then
                creditsRemaining = credits
                creditsExhausted = (credits == 0)
            end

            if requestId and pendingRequests[requestId] then
                local req = pendingRequests[requestId]
                pendingRequests[requestId] = nil
                OnRequestCompleted()

                if req.callback then
                    if err and err ~= "" then
                        -- Store error for UI
                        lastError = err

                        -- Check for credit exhaustion
                        if string.find(err, "INSUFFICIENT_CREDITS") or string.find(err, "Insufficient credits") then
                            creditsExhausted = true
                            creditsRemaining = 0
                        end

                        req.callback(nil, err)
                    else
                        lastError = nil
                        req.callback(translation, nil)
                    end
                end
            end
        end
    end

    -- Cleanup timed-out requests
    local now = GetTime()
    for id, req in pairs(pendingRequests) do
        if now - req.timestamp > REQUEST_TIMEOUT then
            pendingRequests[id] = nil
            OnRequestCompleted()
            if req.callback then
                req.callback(nil, "Request timed out")
            end
        end
    end
end

-- Start the polling frame
function WoWTranslate_API.StartPolling()
    if pollFrame then return end

    pollFrame = CreateFrame("Frame")
    local elapsed = 0

    pollFrame:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed >= POLL_INTERVAL then
            elapsed = 0
            PollTranslations()
        end
    end)
end

-- Stop the polling frame
function WoWTranslate_API.StopPolling()
    if pollFrame then
        pollFrame:SetScript("OnUpdate", nil)
        pollFrame = nil
    end
end

-- ============================================================================
-- OUTGOING TRANSLATION (English -> Chinese)
-- ============================================================================

-- Request an async outgoing translation (en -> zh)
-- callback(translation, error) will be called when complete
function WoWTranslate_API.TranslateOutgoing(text, callback, toLangOverride)
    if not dllAvailable then
        if callback then
            callback(nil, "DLL not available")
        end
        return false
    end

    if not text or text == "" then
        if callback then
            callback(nil, "Empty text")
        end
        return false
    end

    -- Generate unique request ID with "out_" prefix to distinguish from incoming
    requestCounter = requestCounter + 1
    local requestId = "out_" .. tostring(requestCounter)

    -- Store pending request
    pendingRequests[requestId] = {
        callback = callback,
        text = text,
        timestamp = GetTime()
    }

    -- Source is always auto-detected (your own typed text); pick only the target.
    -- toLangOverride lets the caller reply in a whisper partner's language.
    local fromLang = "auto"
    local toLang = toLangOverride or (WoWTranslateDB and WoWTranslateDB.outgoingToLang) or "zh"
    if toLang == "auto" then toLang = "zh" end  -- target must be concrete
    local success, err = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, text, fromLang, toLang)
    end)

    if not success then
        pendingRequests[requestId] = nil
        if callback then
            callback(nil, "DLL call failed: " .. tostring(err))
        end
        return false
    end

    OnRequestQueued()
    return true, requestId
end

-- ============================================================================
-- DEBUG FUNCTIONS
-- ============================================================================

-- Get pending request count
function WoWTranslate_API.GetPendingCount()
    local count = 0
    for _ in pairs(pendingRequests) do
        count = count + 1
    end
    return count
end

-- Get all pending request info (for debugging)
function WoWTranslate_API.GetPendingRequests()
    local info = {}
    local now = GetTime()
    for id, req in pairs(pendingRequests) do
        table.insert(info, {
            id = id,
            text = req.text,
            age = now - req.timestamp
        })
    end
    return info
end

