--[[
    Extension by haruki
    Elasticにログを送信する機能。
]]

---@param ctx LogContext
---@return LogProvider?
return function(ctx)
    local key = GetConvar('elastic:key', '')
    local endpoint = GetConvar('elastic:endpoint', '')
    local index = GetConvar('elastic:index', 'logs-fivem-default')

    if key == '' or endpoint == '' then return end

    local hostname = ctx.hostname
    local formatTags = ctx.formatTags

    local headers = {
        ['Content-Type'] = 'application/x-ndjson',
        ['Authorization'] = ('ApiKey %s'):format(key),
    }

    return {
        endpoint = ('%s/%s/_bulk'):format(endpoint:gsub('/+$', ''), index),
        headers = headers,
        okStatus = 200,
        checkOkResponse = true,

        append = function(buffer, source, event, message, ...)
            local metadata = {}

            local playerTags = formatTags(source, nil)
            if playerTags and type(playerTags) == 'string' then
                local tempTable = { string.strsplit(',', playerTags) }
                for _, v in pairs(tempTable) do
                    local k, vv = string.strsplit(':', v)
                    if k and vv then
                        metadata[k] = vv
                    end
                end
            end

            local args = { ... }
            for _, arg in pairs(args) do
                if type(arg) == 'table' then
                    for k, v in pairs(arg) do
                        metadata[k] = v
                    end
                elseif type(arg) == 'string' then
                    local k, v = string.strsplit(':', arg)
                    if k and v then
                        metadata[k] = v
                    end
                end
            end

            -- json.encode({}) は "[]" になるため、アクション行は文字列で書く
            buffer[#buffer + 1] = '{"create":{}}'
            buffer[#buffer + 1] = json.encode({
                ['@timestamp'] = os.date('!%Y-%m-%dT%H:%M:%SZ'),
                message = message,
                host = { name = hostname },
                service = { name = cache.resource },
                event = { action = event },
                fivem = { source = tostring(source) },
                -- labels = next(labels) and labels or nil,
                metadata = next(metadata) and metadata or nil,
            })
        end,

        encode = function(buffer)
            -- Bulk API は末尾の改行が必須
            return table.concat(buffer, '\n') .. '\n'
        end,

        parseError = function(status, response)
            if type(response) ~= 'string' then return nil end

            if status ~= 200 then
                return json.decode(response:sub(10)) or response
            end

            local result = json.decode(response)
            if not result or not result.errors then return nil end

            local rejected, first = 0, nil

            for i = 1, #result.items do
                local item = result.items[i].create

                if item and item.error then
                    rejected += 1
                    first = first or item.error
                end
            end

            return { rejected = rejected, error = first }
        end,
    }
end