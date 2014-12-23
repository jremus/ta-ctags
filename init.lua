-- Copyright 2007-2014 Mitchell mitchell.att.foicica.com. See LICENSE.

--[[ This comment is for LuaDoc.
---
-- Utilize Ctags with Textadept.
--
-- There are four ways to tell Textadept about *tags* files:
--
--   1. Place a *tags* file in current file's directory. This file will be used
--      in a tag search from any file in that directory.
--   2. Place a *tags* file in a project's root directory. This file will be
--      used in a tag search from any of that project's source files.
--   3. Add a *tags* file or list of *tags* files to the `textadept.ctags` table
--      for a project root key. This file(s) will be used in a tag search from
--      any of that project's source files.
--      For example: `textadept.ctags['/path/to/project'] = '/path/to/tags'`.
--   4. Add a *tags* file to the `textadept.ctags` table. This file will be used
--      in any tag search.
--      For example: `textadept.ctags[#textadept.ctags + 1] = '/path/to/tags'`.
--
-- Textadept will use any and all *tags* files based on the above rules.
module('textadept.ctags')]]

local M = {}

-- Searches file *file* for tag *tag* and appends any matching tags to table
-- *tags*.
-- @param file Ctags file to search. Tags in that file be sorted.
-- @param tag Tag to find.
-- @param tags Table of matching tags.
local function find_tags(file, tag, tags)
  -- TODO: binary search?
  local found = false
  local patt = '^('..tag..'%S*)\t(%S+)\t(.-);"\t?(.*)$'
  local dir = file:match('^.+[/\\]')
  for line in io.lines(file) do
    local tag, file, ex_cmd, ext_fields = line:match(patt)
    if tag then
      if not file:find('^%a?:?[/\\]') then file = dir..file end
      if ex_cmd:find('^/') then ex_cmd = ex_cmd:match('^/^(.+)$/$') end
      tags[#tags + 1] = {tag, file, ex_cmd, ext_fields}
      found = true
    elseif found then
      return -- tags are sorted, so no more matches exist in this file
    end
  end
end

-- List of jump positions comprising a jump history.
-- Has a `pos` field that points to the current jump position.
-- @class table
-- @name jump_list
local jump_list = {pos = 0}
---
-- Jumps to the source of string *tag* or the source of the word under the
-- caret.
-- Prompts the user when multiple sources are found. If *tag* is `nil`, jumps to
-- the previous or next position in the jump history, depending on boolean
-- *prev*.
-- @param tag The tag to jump to the source of.
-- @param prev Optional flag indicating whether to go to the previous position
--   in the jump history or the next one. Only applicable when *tag* is `nil` or
--   `false`.
-- @see tags
-- @name goto_tag
function M.goto_tag(tag, prev)
  if not tag and prev == nil then
    local s = buffer:word_start_position(buffer.current_pos, true)
    local e = buffer:word_end_position(buffer.current_pos, true)
    tag = buffer:text_range(s, e)
  elseif not tag then
    -- Navigate within the jump history.
    if prev and jump_list.pos <= 1 then return end
    if not prev and jump_list.pos == #jump_list then return end
    jump_list.pos = jump_list.pos + (prev and -1 or 1)
    io.open_file(jump_list[jump_list.pos][1])
    buffer:goto_pos(jump_list[jump_list.pos][2])
    return
  end
  -- Search for potential tags to jump to.
  local tags = {}
  -- Search in directory tags.
  local tag_file = ((buffer.filename or ''):match('^.+[/\\]') or
                    lfs.currentdir()..'/')..'tags'
  if lfs.attributes(tag_file) then find_tags(tag_file, tag, tags) end
  if buffer.filename then
    -- Search in project-related tags.
    local root = io.get_project_root(buffer.filename)
    if root then
      -- Project tags.
      tag_file = root..'/tags'
      if lfs.attributes(tag_file) then find_tags(tag_file, tag, tags) end
      -- Project-specified tags.
      tag_file = M[root]
      if type(tag_file) == 'string' then
        find_tags(tag_file, tag, tags)
      elseif type(tag_file) == 'table' then
        for i = 1, #tag_file do find_tags(tag_file[i], tag, tags) end
      end
    end
  end
  -- Search in global tags.
  for i = 1, #M do find_tags(M[i], tag, tags) end
  if #tags == 0 then return end
  tag = tags[1]
  -- Prompt the user to select a tag from multiple candidates.
  if #tags > 1 then
    local items = {}
    for i = 1, #tags do
      items[#items + 1] = tags[i][1]
      items[#items + 1] = tags[i][2]:match('[^/\\]+$') -- filename only
      items[#items + 1] = tags[i][3]:match('^%s*(.+)$') -- strip indentation
      items[#items + 1] = tags[i][4]:match('^%a?%s*(.*)$') -- ignore kind
    end
    local button, i = ui.dialogs.filteredlist{
      title = _L['Go To'],
      columns = {_L['Name'], _L['File'], _L['Line:'], 'Extra Information'},
      items = items, search_column = 2, width = CURSES and ui.size[1] - 2 or nil
    }
    if button < 1 then return end
    tag = tags[i]
  end
  -- Store the current position in the jump history if applicable, clearing any
  -- jump history positions beyond the current one.
  if jump_list.pos < #jump_list then
    for i = jump_list.pos + 1, #jump_list do jump_list[i] = nil end
  end
  if jump_list.pos == 0 or jump_list[#jump_list][1] ~= buffer.filename or
     jump_list[#jump_list][2] ~= buffer.current_pos then
    jump_list[#jump_list + 1] = {buffer.filename, buffer.current_pos}
  end
  -- Jump to the tag.
  io.open_file(tag[2])
  if not tonumber(tag[3]) then
    for i = 0, buffer.line_count - 1 do
      if buffer:get_line(i):find(tag[3], 1, true) then
        textadept.editing.goto_line(i + 1)
        break
      end
    end
  else
    textadept.editing.goto_line(tonumber(tag[3]))
  end
  -- Store the new position in the jump history.
  jump_list[#jump_list + 1] = {buffer.filename, buffer.current_pos}
  jump_list.pos = #jump_list
end

-- Add Ctags functions to the menubar.
-- Connect to `events.INITIALIZED` in order to allow key bindings to be set up
-- such that they reflect accurately in the menu.
events.connect(events.INITIALIZED, function()
  if not textadept.menu then return end
  local tools = textadept.menu.menubar[4]
  tools[#tools + 1] = {''} -- separator
  tools[#tools + 1] = {
    title = 'Ctags',
    {'Goto Ctag', M.goto_tag},
    {'Jump Back', {M.goto_tag, nil, true}},
    {'Jump Forward', {M.goto_tag, nil, false}}
  }
end)

return M
