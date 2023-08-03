--[[
Generates lua-ls annotations for lsp
USAGE:
nvim -l scripts/gen_lsp.lua gen  # this will overwrite runtime/lua/vim/lsp/types/protocol.lua
nvim -l scripts/gen_lsp.lua gen --version 3.18 --build/new_lsp_types.lua
nvim -l scripts/gen_lsp.lua gen --version 3.18 --out runtime/lua/vim/lsp/types/protocol.lua
nvim -l scripts/gen_lsp.lua gen --version 3.18 --methods
--]]

local M = {}

local function tofile(fname, text)
  local f = io.open(fname, 'w')
  if not f then
    error(('failed to write: %s'):format(f))
  else
    f:write(text)
    f:close()
  end
end

local function read_json(opt)
  local uri = 'https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/'
    .. opt.version
    .. '/metaModel/metaModel.json'

  local res = vim.system({ 'curl', '--no-progress-meter', uri, '-o', '-' }):wait()
  if res.code ~= 0 or (res.stdout or ''):len() < 999 then
    print(('URL failed: %s'):format(uri))
    vim.print(res)
    error(res.stdout)
  end
  return vim.json.decode(res.stdout)
end

-- Gets the Lua symbol for a given fully-qualified LSP method name.
local function name(s)
  -- "$/" prefix is special: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#dollarRequests
  return s:gsub('^%$', 'dollar'):gsub('/', '_')
end

local function gen_methods(protocol)
  local output = {
    '-- Generated by gen_lsp.lua, keep at end of file.',
    '--- LSP method names.',
    '---',
    '---@see https://microsoft.github.io/language-server-protocol/specifications/specification-current/#metaModel',
    'protocol.Methods = {',
  }
  local indent = (' '):rep(2)

  local all = vim.list_extend(protocol.requests, protocol.notifications)
  table.sort(all, function(a, b)
    return name(a.method) < name(b.method)
  end)
  for _, item in ipairs(all) do
    if item.method then
      if item.documentation then
        local document = vim.split(item.documentation, '\n?\n', { trimempty = true })
        for _, docstring in ipairs(document) do
          output[#output + 1] = indent .. '--- ' .. docstring
        end
      end
      output[#output + 1] = ("%s%s = '%s',"):format(indent, name(item.method), item.method)
    end
  end
  output[#output + 1] = '}'
  output = vim.list_extend(
    output,
    vim.split(
      [[
local function freeze(t)
  return setmetatable({}, {
    __index = t,
    __newindex = function()
      error('cannot modify immutable table')
    end,
  })
end
protocol.Methods = freeze(protocol.Methods)

return protocol
]],
      '\n',
      { trimempty = true }
    )
  )

  local fname = './runtime/lua/vim/lsp/protocol.lua'
  local bufnr = vim.fn.bufadd(fname)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local index = vim.iter(ipairs(lines)):find(function(key, item)
    return vim.startswith(item, '-- Generated by') and key or nil
  end)
  index = index and index - 1 or vim.api.nvim_buf_line_count(bufnr) - 1
  vim.api.nvim_buf_set_lines(bufnr, index, -1, true, output)
  vim.cmd.write()
end

function M.gen(opt)
  local protocol = read_json(opt)

  if opt.methods then
    gen_methods(protocol)
  end

  local output = {
    '--[[',
    'This file is autogenerated from scripts/gen_lsp.lua',
    'Regenerate:',
    [=[nvim -l scripts/gen_lsp.lua gen --version 3.18 --runtime/lua/vim/lsp/types/protocol.lua]=],
    '--]]',
    '',
    '---@alias lsp.null nil',
    '---@alias uinteger integer',
    '---@alias lsp.decimal number',
    '---@alias lsp.DocumentUri string',
    '---@alias lsp.URI string',
    '---@alias lsp.LSPObject table<string, lsp.LSPAny>',
    '---@alias lsp.LSPArray lsp.LSPAny[]',
    '---@alias lsp.LSPAny lsp.LSPObject|lsp.LSPArray|string|number|boolean|nil',
    '',
  }

  local anonymous_num = 0

  local anonym_classes = {}

  local simple_types = {
    'string',
    'boolean',
    'integer',
    'uinteger',
    'decimal',
  }

  local function parse_type(type)
    if type.kind == 'reference' or type.kind == 'base' then
      if vim.tbl_contains(simple_types, type.name) then
        return type.name
      end
      return 'lsp.' .. type.name
    elseif type.kind == 'array' then
      return parse_type(type.element) .. '[]'
    elseif type.kind == 'or' then
      local val = ''
      for _, item in ipairs(type.items) do
        val = val .. parse_type(item) .. '|'
      end
      val = val:sub(0, -2)
      return val
    elseif type.kind == 'stringLiteral' then
      return '"' .. type.value .. '"'
    elseif type.kind == 'map' then
      return 'table<' .. parse_type(type.key) .. ', ' .. parse_type(type.value) .. '>'
    elseif type.kind == 'literal' then
      -- can I use ---@param disabled? {reason: string}
      -- use | to continue the inline class to be able to add docs
      -- https://github.com/LuaLS/lua-language-server/issues/2128
      anonymous_num = anonymous_num + 1
      local anonym = { '---@class anonym' .. anonymous_num }
      for _, field in ipairs(type.value.properties) do
        if field.documentation then
          field.documentation = field.documentation:gsub('\n', '\n---')
          anonym[#anonym + 1] = '---' .. field.documentation
        end
        anonym[#anonym + 1] = '---@field '
          .. field.name
          .. (field.optional and '?' or '')
          .. ' '
          .. parse_type(field.type)
      end
      anonym[#anonym + 1] = ''
      for _, line in ipairs(anonym) do
        anonym_classes[#anonym_classes + 1] = line
      end
      return 'anonym' .. anonymous_num
    elseif type.kind == 'tuple' then
      local tuple = '{ '
      for i, value in ipairs(type.items) do
        tuple = tuple .. '[' .. i .. ']: ' .. parse_type(value) .. ', '
      end
      -- remove , at the end
      tuple = tuple:sub(0, -3)
      return tuple .. ' }'
    end
    vim.print(type)
    return ''
  end

  for _, structure in ipairs(protocol.structures) do
    if structure.documentation then
      structure.documentation = structure.documentation:gsub('\n', '\n---')
      output[#output + 1] = '---' .. structure.documentation
    end
    if structure.extends then
      local class_string = '---@class lsp.'
        .. structure.name
        .. ': '
        .. parse_type(structure.extends[1])
      for _, mixin in ipairs(structure.mixins or {}) do
        class_string = class_string .. ', ' .. parse_type(mixin)
      end
      output[#output + 1] = class_string
    else
      output[#output + 1] = '---@class lsp.' .. structure.name
    end
    for _, field in ipairs(structure.properties or {}) do
      if field.documentation then
        field.documentation = field.documentation:gsub('\n', '\n---')
        output[#output + 1] = '---' .. field.documentation
      end
      output[#output + 1] = '---@field '
        .. field.name
        .. (field.optional and '?' or '')
        .. ' '
        .. parse_type(field.type)
    end
    output[#output + 1] = ''
  end

  for _, enum in ipairs(protocol.enumerations) do
    if enum.documentation then
      enum.documentation = enum.documentation:gsub('\n', '\n---')
      output[#output + 1] = '---' .. enum.documentation
    end
    local enum_type = '---@alias lsp.' .. enum.name
    for _, value in ipairs(enum.values) do
      enum_type = enum_type
        .. '\n---| '
        .. (type(value.value) == 'string' and '"' .. value.value .. '"' or value.value)
        .. ' # '
        .. value.name
    end
    output[#output + 1] = enum_type
    output[#output + 1] = ''
  end

  for _, alias in ipairs(protocol.typeAliases) do
    if alias.documentation then
      alias.documentation = alias.documentation:gsub('\n', '\n---')
      output[#output + 1] = '---' .. alias.documentation
    end
    if alias.type.kind == 'or' then
      local alias_type = '---@alias lsp.' .. alias.name .. ' '
      for _, item in ipairs(alias.type.items) do
        alias_type = alias_type .. parse_type(item) .. '|'
      end
      alias_type = alias_type:sub(0, -2)
      output[#output + 1] = alias_type
    else
      output[#output + 1] = '---@alias lsp.' .. alias.name .. ' ' .. parse_type(alias.type)
    end
    output[#output + 1] = ''
  end

  for _, line in ipairs(anonym_classes) do
    output[#output + 1] = line
  end

  tofile(opt.output_file, table.concat(output, '\n'))
end

local opt = {
  output_file = 'runtime/lua/vim/lsp/types/protocol.lua',
  version = nil,
  methods = nil,
}

for i = 1, #_G.arg do
  if _G.arg[i] == '--out' then
    opt.output_file = _G.arg[i + 1]
  elseif _G.arg[i] == '--version' then
    opt.version = _G.arg[i + 1]
  elseif _G.arg[i] == '--methods' then
    opt.methods = true
  elseif vim.startswith(_G.arg[i], '--') then
    opt.output_file = _G.arg[i]:sub(3)
  end
end

for _, a in ipairs(arg) do
  if M[a] then
    M[a](opt)
  end
end

return M
