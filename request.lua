local cjson = require ('cjson.safe')
local ngx_req = ngx.req
local read_body = ngx_req.read_body
local get_body_data = ngx_req.get_body_data
local get_body_file = ngx_req.get_body_file
local inspect = require 'inspect'

local file_reader = require("resty.file").file_reader

local _M = {}

-- Assuming that all request will be JSON
local function get_body()
  local err
  read_body()

  local body = get_body_data()
  if not body then
    local temp_file_path = get_body_file()

    if not temp_file_path then
      return ""
    end

    body, err = file_reader(temp_file_path)
    if err then
      return nil, err
    end
  end
  return body
end

function _M.get_json_body()
  local body, err = get_body()
  if not body then
    return nil, "failed to read request body err: "..err
  end

  local json = cjson.decode(body)
  if type(json) ~= "table" then
    return nil, "invalid json body"
  end
  return json
end

return _M
