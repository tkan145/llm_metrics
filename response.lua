local buffer = require "string.buffer"
local cjson = require 'cjson.safe'
local Mime = require 'resty.mime'

local arg = ngx.arg

local json_content_types = {
  ["application/json"] = true,
}

local _M = {}

-- Buffering the response body in the internal request context
-- and return the full body when last chunk has been read
function _M.get_raw_body()
  local buffered = ngx.ctx.buffered_response_body
  local chunk, eof = ngx.arg[1], ngx.arg[2]


  -- Single chunk
  if eof and not buffered then
    return chunk
  end

  if type(chunk) == "string" and chunk ~= "" then
    if not buffered then
      buffered = {} -- XXX we can use table.new here
      ngx.ctx.buffered_response_body = buffered
    end

    buffered[#buffered+1] = chunk
    ngx.arg[1] = nil
  end

  -- End of chunk
  if eof then
    if buffered then
      buffered = table.concat(buffered)
    else
      buffered = ""
    end

    -- Send response and clear the buffered body
    arg[1] = buffered
    ngx.ctx.buffered_response_body = nil
    return buffered
  end

  arg[1] = nil
  return nil
end

local function mime_type(content_type)
    return Mime.new(content_type).media_type
end

function _M.decode_json(response)
    if json_content_types[mime_type(response.headers.content_type)] then
        return cjson.decode(response.body)
    else
        return nil, 'not json'
    end
end

function _M.get_json_body()
  local response_body = _M.get_raw_body()
  if response_body then
    local err
    if type(response_body) == "string" then
      response_body, err = cjson.decode(response_body)
      if err then
        return nil, err
      end
      return response_body
    else
      return nil, "unknown response body type"
    end
  end

  return nil
end

return _M
