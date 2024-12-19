local len = string.len
local ipairs = ipairs
local pairs = pairs
local tinsert = table.insert

local policy = require('apicast.policy')
local prometheus = require('apicast.prometheus')
local Condition = require('apicast.conditions.condition')
local LinkedList = require('apicast.linked_list')
local TemplateString = require('apicast.template_string')
local Operation = require('apicast.conditions.operation')
local Usage = require('apicast.usage')
local resty_env = require ('resty.env')

local response = require ('response')
local portal_client = require('portal_client')
local custom_metrics = require('custom_metrics')

local default_combine_op = "and"
local default_template_type = "plain"
local liquid_template_type = "liquid"

local _M = policy.new('LLM metrics', 'builtin')

local new = _M.new

-- Register metrics
local llm_prompt_tokens_count = prometheus(
  'counter',
  'llm_prompt_tokens_count',
  'Token count for a prompt',
  {'service_id', 'service_system_name', 'application_id', 'application_system_name'}
)

local llm_completion_tokens_count = prometheus(
  'counter',
  'llm_completion_tokens_count',
  "Token cout for a completion",
  {'service_id', 'service_system_name', 'application_id', 'application_system_name'}
)

local llm_total_token_count = prometheus(
  'counter',
  'llm_total_token_count',
  "Total token count",
  {'service_id', 'service_system_name', 'application_id', 'application_system_name'}
)

local function get_context(context)
  local ctx = { }
  ctx.req = {
    headers=ngx.req.get_headers(),
  }

  ctx.resp = {
    headers=ngx.resp.get_headers(),
  }

  ctx.usage = context.usage
  ctx.service = context.service or {}
  ctx.original_request = context.original_request
  ctx.jwt = context.jwt or {}
  ctx.application = context.application or {}
  ctx.usuage = context.usage or {}
  return LinkedList.readonly(ctx, ngx.var)
end

local function load_condition(condition_config)
  if not condition_config then
    return nil
  end
  local operations = {}
  for _, operation in ipairs(condition_config.operations or {}) do
    tinsert( operations,
      Operation.new(
        operation.left,
        operation.left_type or default_template_type,
        operation.op,
        operation.right,
        operation.right_type or default_template_type))
  end

  return Condition.new(
    operations,
    condition_config.combine_op or default_combine_op)
end

local function load_rules(self, config_rules)
  if not config_rules then
    return
  end
  local rules = {}
  for _,rule in pairs(config_rules) do
      tinsert(rules, {
        condition = load_condition(rule.condition),
        metric = TemplateString.new(rule.metric or "", liquid_template_type),
        increment = TemplateString.new(rule.increment or "0", liquid_template_type)
      })
  end
  self.rules = rules
end

--- Initialize llm policy
-- @tparam[opt] table config Policy configuration.
function _M.new(config)
  local self = new(config)
  self.endpoint = resty_env.get('THREESCALE_PORTAL_ENDPOINT')
  self.rules = {}
  load_rules(self, config.rules or {})
  return self
end

-- Need to fetch application here as cosocket is disbaled
-- in body_filter phase
function _M:access(context)
  local service = context.service
  if not service then
    ngx.log(ngx.ERR, 'No service in the context')
    return
  end

  local credentials = context.credentials
  if not credentials then
    ngx.log(ngx.WARN, "cannot get credentials: ", err or 'unknown error')
    return
  end

  local application, err = portal_client.find_application(self.endpoint, service.id, credentials)
  if not application then
    ngx.log(ngx.WARN, "cannot get application details: ", err or 'unknown error')
    return
  end

  context.application = application
end

function _M:body_filter(context)
  local response_body, err = response.get_json_body()
  if err then
    ngx.log(ngx.ERR, "unabled to read response_body, err: " .. err)
    ngx.exit(500)
  end

  if response_body then
    -- Read the response body and extract usuage
    local service = context.service
    if not service then
      ngx.log(ngx.ERR, 'No service in the context')
      return
    end

    local credentials = context.credentials
    if not credentials then
      ngx.log(ngx.WARN, "cannot get credentials: ", err or 'unknown error')
      return
    end

    local application = context.application

    local usuage = response_body.usage
    context.usuage = usuage

    if usuage and usuage.prompt_tokens and usuage.prompt_tokens > 0 then
      llm_prompt_tokens_count:inc(usuage.prompt_tokens, {
        service.id or "",
        service.system_name or "",
        application.id or "",
        application.name or ""
      })
    end

    if usuage and usuage.completion_tokens and usuage.completion_tokens > 0 then
      llm_completion_tokens_count:inc(usuage.completion_tokens, {
        service.id or "",
        service.system_name or "",
        application.id or "",
        application.name or ""
      })
    end

    if usuage and usuage.total_tokens and usuage.total_tokens > 0 then
      llm_total_token_count:inc(usuage.total_tokens, {
        service.id or "",
        service.system_name or "",
        application.id or "",
        application.name or ""
      })
    end
  end
end

function _M:post_action(context)
  -- context with all variables are needed to retrieve information about API
  -- response
  local ctx = get_context(context)

  -- We initilize the usage, and if any rule match, we report the usage to
  -- backend.
  local match = false
  local usage = Usage.new()

  for _, rule in ipairs(self.rules) do
    if rule.condition:evaluate(ctx) then
      local metric = rule.metric:render(ctx)
      if len(metric) > 0 then
        usage:add(metric, tonumber(rule.increment:render(ctx)) or 0)
        match = true
      end
    end
  end

  if not match then
    return
  end

  -- If cached key authrep call will happen on APICast policy, so no need to
  -- report only one metric. If no cached key will report only the new metrics.
  if ngx.var.cached_key then
    context.usage:merge(usage)
    return
  end
  custom_metrics.report(context, usage)
end

return _M
