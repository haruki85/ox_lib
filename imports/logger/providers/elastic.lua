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

    ---source（サーバーID または citizenid）から qbx_core のキャラクター情報とサーバーIDを取得する
    local function getCharacter(source)
        if GetResourceState('qbx_core') ~= 'started' then return end

        local ok, player = pcall(function()
            if type(source) == 'number' and source > 0 then
                return exports.qbx_core:GetPlayer(source)
            elseif type(source) == 'string' then
                return exports.qbx_core:GetPlayerByCitizenId(source)
            end
        end)

        if not ok or not player then return end

        local data = player.PlayerData

        return {
            citizenid = data.citizenid,
            name = ('%s %s'):format(data.charinfo.lastname, data.charinfo.firstname),
        }, data.source
    end

    ---"key:value,key:value" 形式のタグを tbl に展開する
    local function parseTags(str, tbl)
        for _, tag in ipairs({ string.strsplit(',', str) }) do
            local k, v = tag:match('^([^:]+):(.*)$')

            if k then
                tbl[k] = v
            end
        end
    end

    local headers = {
        ['Content-Type'] = 'application/x-ndjson',
        ['Authorization'] = ('ApiKey %s'):format(key),
    }

    return {
        -- filter_path で失敗したドキュメントだけを返させる
        endpoint = ('%s/%s/_bulk?filter_path=errors,items.*.error'):format(endpoint:gsub('/+$', ''), index),
        headers = headers,
        okStatus = 200,
        checkOkResponse = true,

        append = function(buffer, source, event, message, ...)
            local character, playerSource = getCharacter(source)
            local metadata = {}

            -- source が citizenid でも、サーバーIDが分かれば識別子を付ける
            local playerTags = formatTags(playerSource or source, nil)
            if playerTags then
                parseTags(playerTags, metadata)
            end

            for _, arg in pairs({ ... }) do
                if type(arg) == 'table' then
                    for k, v in pairs(arg) do
                        metadata[k] = v
                    end
                elseif type(arg) == 'string' then
                    parseTags(arg, metadata)
                end
            end

            local ok, doc = pcall(json.encode, {
                ['@timestamp'] = os.date('!%Y-%m-%dT%H:%M:%SZ'),
                message = message,
                host = { name = hostname },
                service = { name = cache.resource },
                event = { action = event },
                fivem = {
                    source = tostring(source),
                    character = character,
                },
                metadata = next(metadata) and metadata or nil,
            })

            -- 関数や循環参照を含むテーブルは JSON にできないので、そのログだけ捨てる
            if not ok then
                lib.print.warn(('unable to encode log "%s" for elastic: %s'):format(event, doc))
                return
            end

            -- json.encode({}) は "[]" になるため、アクション行は文字列で書く
            buffer[#buffer + 1] = '{"create":{}}'
            buffer[#buffer + 1] = doc
        end,

        encode = function(buffer)
            -- Bulk API は末尾の改行が必須
            return table.concat(buffer, '\n') .. '\n'
        end,

        parseError = function(status, response)
            if status ~= 200 then
                -- 接続自体に失敗した場合（TLS エラーなど）は response が文字列で来ないことがある
                if type(response) ~= 'string' then return 'no response' end

                return json.decode(response:sub(10)) or response
            end

            if type(response) ~= 'string' then return nil end

            local result = json.decode(response)
            if not result or not result.errors then return nil end

            local items = result.items or {}
            local first = items[1] and items[1].create

            return { rejected = #items, error = first and first.error }
        end,
    }
end
