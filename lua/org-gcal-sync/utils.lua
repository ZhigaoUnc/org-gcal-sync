-- lua/org-gcal-sync/utils.lua
local M = {}
local gcal_api = require("org-gcal-sync.gcal_api")
local conflict = require("org-gcal-sync.conflict")
local dashboard = require("org-gcal-sync.dashboard")

-- We'll get config from init.lua later
local cfg = {}

-- === CONFIG INJECTION ===
function M.set_config(config)
  cfg = config
end

-- Helpers --------------------------------------------------------------------
local function norm_time(ts)
  return ts and ts:gsub("^(%d%d%d%d%-%d%d%-%d%d)%s+(%d?%d:%d%d).*", "%1 %2") or nil
end

M.make_key = function(title, time, event_id)
  if event_id then
    return event_id
  end
  return (title or ""):lower() .. "||" .. (norm_time(time) or "")
end

-- Split file lines into headline blocks. Returns list of {start, finish, lines}
-- where `start` is the 1-indexed line number of the headline.
local function split_headline_blocks(lines)
  local blocks = {}
  local block_start = nil
  for i, l in ipairs(lines) do
    if l:match("^%*+%s") then
      if block_start then
        table.insert(blocks, { start = block_start, finish = i - 1 })
      end
      block_start = i
    end
  end
  if block_start then
    table.insert(blocks, { start = block_start, finish = #lines })
  end
  return blocks
end

-- Reset per-headline parse state
local function fresh_state()
  return {
    title = nil, ts = nil, event_id = nil, location = "",
    description = "", is_todo = false, in_properties = false,
  }
end

-- Add one day to a date string "YYYY-MM-DD", no timezone issues
local function next_date_str(date_str)
  local y, m, d = tonumber(date_str:match("(%d%d%d%d)")), tonumber(date_str:match("%d%d%d%d%-(%d%d)")), tonumber(date_str:match("%d%d%d%d%-%d%d%-(%d%d)"))
  d = d + 1
  local dim = {31, 28 + (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) and 1 or 0), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
  if d > dim[m] then
    d = 1
    m = m + 1
    if m > 12 then
      m = 1
      y = y + 1
    end
  end
  return string.format("%04d-%02d-%02d", y, m, d)
end

local function parse_gcal_datetime(dt)
  if not dt then return nil end
  if dt.dateTime then
    local ts = dt.dateTime:gsub("T", " "):gsub("[+-]%d%d:%d%d$", ""):gsub("Z$", "")
    return ts:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d")
  elseif dt.date then
    return dt.date
  end
  return nil
end

M.get_gcal_events = function(calendar_id)
  local time_min = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 7 * 24 * 60 * 60)
  local time_max = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 90 * 24 * 60 * 60)
  
  local events, err = gcal_api.list_events(time_min, time_max, calendar_id)
  if not events then
    vim.notify("Failed to fetch events: " .. (err or "unknown error"), vim.log.levels.ERROR)
    if cfg.show_sync_status then
      dashboard.add_error("Failed to fetch events: " .. (err or "unknown error"))
    end
    return nil, err
  end

  local ev = {}
  for _, event in ipairs(events) do
    if event.summary then
      local instances = { event }
      
      if cfg.sync_recurring_events and event.recurrence then
        instances = gcal_api.expand_recurring_event(event, time_min, time_max)
      end
      
      for _, instance in ipairs(instances) do
        local ts = parse_gcal_datetime(instance.start)
        if ts then
          local key = M.make_key(instance.summary, ts, instance.id)
          ev[key] = {
            id = instance.id,
            title = instance.summary,
            timestamp = ts,
            location = instance.location or "",
            description = instance.description or "",
            updated = instance.updated,
            calendar_id = calendar_id or "primary",
            recurring_event_id = event.recurringEventId,
            recurrence = event.recurrence,
          }
        end
      end
    end
  end
  return ev
end

M.get_existing_roam_events = function()
  local map = {}
  
  local import_dir = cfg.org_dirs[1] or cfg.agenda_dir
  if not import_dir then
    vim.notify("org-gcal-sync: No org_dirs configured. Please add org_dirs to your setup.", vim.log.levels.ERROR)
    return map
  end
  local expanded_dir = vim.fn.expand(import_dir)
  local files = vim.fn.globpath(expanded_dir, "**/*.org", false, true)
  files = vim.tbl_filter(function(f) return not f:match("_archive$") end, files)
  
  for _, f in ipairs(files) do
    local lines = vim.fn.readfile(f)
    
    local file_modified = nil
    if vim.fn.filereadable(f) == 1 then
      local stat = vim.loop.fs_stat(f)
      if stat then
        file_modified = os.date("!%Y-%m-%dT%H:%M:%SZ", stat.mtime.sec)
      end
    end
    
    local title, ts, event_id, gcal_updated, calendar_id = nil, nil, nil, nil, nil
    local in_properties = false
    
    local function save_headline()
      if title and ts then
        local key = M.make_key(title, ts, event_id)
        if not map[key] then
          map[key] = {
            path = f,
            title = title,
            timestamp = ts,
            event_id = event_id,
            gcal_updated = gcal_updated,
            calendar_id = calendar_id or "primary",
            modified = file_modified,
          }
        end
      end
    end
    
    for _, l in ipairs(lines) do
      local t = l:gsub("^%s*(.-)%s*$", "%1")
      if t:match("^%*+%s") then
        save_headline()
        title = t:match("^%*+%s+(.*)")
        ts, event_id, gcal_updated, calendar_id = nil, nil, nil, nil
        in_properties = false
      elseif t:match("SCHEDULED:") or t:match("DEADLINE:") then
        ts = t:match("<([^>]+)>")
      elseif t == ":PROPERTIES:" then
        in_properties = true
      elseif t == ":END:" then
        in_properties = false
      elseif in_properties and t:match("^:GCAL_ID:") then
        event_id = t:match("^:GCAL_ID:%s*(.+)%s*$")
      elseif in_properties and t:match("^:GCAL_UPDATED:") then
        gcal_updated = t:match("^:GCAL_UPDATED:%s*(.+)%s*$")
      elseif in_properties and t:match("^:CALENDAR_ID:") then
        calendar_id = t:match("^:CALENDAR_ID:%s*(.+)%s*$")
      end
    end
    save_headline()
  end
  return map
end

local function generate_uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function(c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end)
end

local function slugify(title)
  if cfg.slug_func then return cfg.slug_func(title) end
  return title
    :lower()
    :gsub("[^%w%s-]", "")
    :gsub("%s+", "-")
    :gsub("-+", "-")
    :gsub("^-+", "")
    :gsub("-+$", "")
    .. ".org"
end

local function find_mentioning_notes(title)
  local dirs = cfg.org_dirs
  if #dirs == 0 then return {} end
  local pattern = vim.fn.shellescape(title)
  local cmd = string.format('grep -iFl %s %s 2>/dev/null || true', pattern, table.concat(vim.tbl_map(vim.fn.expand, dirs), " "))
  local out = vim.fn.system(cmd)
  local files = {}
  for f in out:gmatch("[^\r\n]+") do
    if vim.fn.filereadable(f) == 1 then table.insert(files, f) end
  end
  return files
end

local function add_backlink(note_path, event_file)
  local lines = vim.fn.readfile(note_path)
  local new_lines = {}
  local in_prop = false
  local has_ref = false

  for _, line in ipairs(lines) do
    local t = line:gsub("^%s*(.-)%s*$", "%1")
    if t == ":PROPERTIES:" then in_prop = true end
    if in_prop and t == ":END:" then
      in_prop = false
      if not has_ref then
        table.insert(new_lines, "  :ROAM_REFS: " .. vim.fn.fnameescape("file:" .. event_file))
        has_ref = true
      end
    end
    if in_prop and t:match("^:ROAM_REFS:") then
      has_ref = true
      if not t:find(vim.fn.fnameescape(event_file), 1, true) then
        line = line .. " " .. vim.fn.fnameescape("file:" .. event_file)
      end
    end
    table.insert(new_lines, line)
  end

  if not has_ref then
    local insert_at = 1
    for i, l in ipairs(lines) do
      if l:match("^%*+%s") then insert_at = i; break end
    end
    table.insert(new_lines, insert_at, "  :PROPERTIES:")
    table.insert(new_lines, insert_at + 1, "  :ROAM_REFS: " .. vim.fn.fnameescape("file:" .. event_file))
    table.insert(new_lines, insert_at + 2, "  :END:")
  end

  vim.fn.writefile(new_lines, note_path)
end

M.write_roam_event_note = function(path, data)
  -- Check if file already exists - if so, update it instead of overwriting
  if vim.fn.filereadable(path) == 1 then
    return M.update_roam_event_note(path, data)
  end
  
  -- Create new file
  local lines = {
    ":PROPERTIES:",
    ":ID: " .. generate_uuid(),
    ":END:",
    "#+title: " .. data.title,
    "#+filetags: :gcal:",
    "",
    "* " .. data.title,
    "  SCHEDULED: <" .. data.timestamp .. ">",
    "  :PROPERTIES:",
  }
  if data.event_id then
    table.insert(lines, "  :GCAL_ID: " .. data.event_id)
  end
  if data.calendar_id then
    table.insert(lines, "  :CALENDAR_ID: " .. data.calendar_id)
  end
  if data.location and data.location ~= "" then
    table.insert(lines, "  :LOCATION: " .. data.location)
  end
  if data.updated then
    table.insert(lines, "  :GCAL_UPDATED: " .. data.updated)
  end
  if data.recurring_event_id then
    table.insert(lines, "  :RECURRING_EVENT_ID: " .. data.recurring_event_id)
  end
  if data.recurrence then
    table.insert(lines, "  :RECURRENCE: " .. vim.json.encode(data.recurrence))
  end
  table.insert(lines, "  :END:")
  
  if data.description and data.description ~= "" then
    table.insert(lines, "")
    vim.list_extend(lines, vim.split("  " .. data.description:gsub("\n", "\n  "), "\n"))
  end
  table.insert(lines, "")
  vim.fn.writefile(lines, path)

  -- Only add backlinks if org-roam is available and enabled
  if cfg.enable_backlinks then
    local has_org_roam = pcall(require, "org-roam")
    if has_org_roam then
      local mentions = find_mentioning_notes(data.title)
      for _, note in ipairs(mentions) do
        if note ~= path then add_backlink(note, path) end
      end
    end
  end
end

-- Smart update: Only update what changed in Google Calendar, preserve org-mode features
M.update_roam_event_note = function(path, data)
  local lines = vim.fn.readfile(path)
  local new_lines = {}
  local in_properties = false
  local in_logbook = false
  local in_file_props = false
  local found_headline = false
  
  for i, line in ipairs(lines) do
    local t = line:gsub("^%s*(.-)%s*$", "%1")
    local updated_line = line
    
    -- Track file-level properties drawer (at start of file)
    if i <= 5 and t == ":PROPERTIES:" then
      in_file_props = true
    elseif in_file_props and t == ":END:" then
      in_file_props = false
    elseif in_file_props then
      -- NEVER update file-level properties (ID, CATEGORY, etc.)
      -- These are org-specific
      table.insert(new_lines, line)
      goto continue
    end
    
    -- NEVER update frontmatter - it's org-specific
    if t:match("^#%+") then
      table.insert(new_lines, line)
      goto continue
    end
    
    -- Update headline: preserve TODO/NEXT, priority, only update title text
    if not found_headline and t:match("^%*+%s+") then
      found_headline = true
      local stars = t:match("^(%*+)")
      local todo_keyword = t:match("^%*+%s+(TODO)") or t:match("^%*+%s+(NEXT)") or ""
      local priority = t:match("%[#([ABC])%]") or ""
      local old_title = t:match("^%*+%s+TODO%s+%[#[ABC]%]%s+(.*)") or
                        t:match("^%*+%s+TODO%s+(.*)") or
                        t:match("^%*+%s+NEXT%s+%[#[ABC]%]%s+(.*)") or
                        t:match("^%*+%s+NEXT%s+(.*)") or
                        t:match("^%*+%s+(.*)")
      
      -- Only update title if it changed
      if old_title and old_title ~= data.title then
        local new_headline = stars .. " "
        if todo_keyword ~= "" then
          new_headline = new_headline .. todo_keyword .. " "
        end
        if priority ~= "" then
          new_headline = new_headline .. "[#" .. priority .. "] "
        end
        new_headline = new_headline .. data.title
        updated_line = new_headline
      end
    end
    
    -- Track LOGBOOK drawer
    if t == ":LOGBOOK:" then
      in_logbook = true
    elseif in_logbook and t == ":END:" then
      in_logbook = false
    end
    
    -- NEVER update LOGBOOK - it's org-specific state tracking
    if in_logbook or t == ":LOGBOOK:" then
      table.insert(new_lines, line)
      goto continue
    end
    
    -- Update headline-level properties drawer
    if t == ":PROPERTIES:" and found_headline then
      in_properties = true
    elseif in_properties and t == ":END:" then
      in_properties = false
    elseif in_properties then
      -- Only update Google Calendar-specific properties
      if t:match("^:GCAL_ID:") and data.event_id then
        updated_line = "  :GCAL_ID: " .. data.event_id
      elseif t:match("^:GCAL_UPDATED:") and data.updated then
        updated_line = "  :GCAL_UPDATED: " .. data.updated
      elseif t:match("^:LOCATION:") then
        if data.location and data.location ~= "" then
          updated_line = "  :LOCATION: " .. data.location
        else
          -- Location removed in Google Calendar
          updated_line = nil
        end
      elseif t:match("^:CALENDAR_ID:") and data.calendar_id then
        updated_line = "  :CALENDAR_ID: " .. data.calendar_id
      end
      -- All other properties (LAST_REPEAT, CATEGORY, custom) are preserved
    end
    
    -- Smart SCHEDULED/DEADLINE update
    if t:match("^SCHEDULED:") or t:match("^DEADLINE:") then
      -- Extract current timestamp from line
      local current_ts = line:match("<([^>]+)>")
      local has_timespan = line:match("%-%-<")
      local has_repeater = line:match("%.%+")
      
      -- Parse Google Calendar timestamp
      local gcal_ts = data.timestamp
      
      -- Only update if timestamp actually changed
      -- Compare dates/times, ignore day names
      local current_date_time = current_ts and current_ts:match("(%d%d%d%d%-%d%d%-%d%d[^%.>]*)")
      local gcal_date_time = gcal_ts and gcal_ts:match("(%d%d%d%d%-%d%d%-%d%d[^%.>]*)")
      
      if current_date_time ~= gcal_date_time then
        -- Time changed in Google Calendar - update it
        -- But preserve local format (timespan, repeater)
        if has_timespan then
          -- Has timespan - preserve it, update start time only
          -- Keep the exact format including day name
          local day_name = gcal_ts:match("%a+") or current_ts:match("%a+") or ""
          updated_line = line:gsub("<[^>]+>", "<" .. gcal_ts .. ">", 1)
        elseif has_repeater then
          -- Has repeater - preserve it
          local repeater = line:match("(%.%+[^>]+)")
          updated_line = "  SCHEDULED: <" .. gcal_ts .. " " .. repeater .. ">"
        else
          -- Simple timestamp - update it
          updated_line = "  SCHEDULED: <" .. gcal_ts .. ">"
        end
      end
      -- If timestamp unchanged, preserve line exactly as-is (including repeater, timespan)
    end
    
    if updated_line then
      table.insert(new_lines, updated_line)
    end
    
    ::continue::
  end
  
  vim.fn.writefile(new_lines, path)
end

-- Single-file import helpers --------------------------------------------------
local function import_filename_for_calendar(calendar_id)
  if calendar_id == "primary" then
    return "gcal-imports.org"
  end
  local slug = calendar_id
    :lower()
    :gsub("@.*", "")
    :gsub("[^%w]", "_")
    :gsub("_+", "_")
    :gsub("^_", "")
    :gsub("_$", "")
  if slug == "" then slug = "calendar" end
  return "gcal-imports_" .. slug .. ".org"
end

local function find_headline_by_event_id(lines, event_id)
  local in_properties = false
  local current_headline = nil
  local escaped_id = event_id:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
  for i, l in ipairs(lines) do
    local t = l:gsub("^%s*(.-)%s*$", "%1")
    if t:match("^%*+%s") then
      current_headline = i
      in_properties = false
    elseif t == ":PROPERTIES:" then
      in_properties = true
    elseif t == ":END:" then
      in_properties = false
    elseif in_properties and t:match("^:GCAL_ID:%s*" .. escaped_id .. "%s*$") then
      return current_headline
    end
  end
  return nil
end

local function update_event_in_file(path, data, headline_line)
  local lines = vim.fn.readfile(path)
  local block_end = #lines
  for i = headline_line + 1, #lines do
    if lines[i]:match("^%*+%s") then
      block_end = i - 1
      break
    end
  end

  local result = {}
  for i = 1, headline_line - 1 do
    table.insert(result, lines[i])
  end

  local stars = lines[headline_line]:match("^(%*+)")
  local todo = lines[headline_line]:match("^%*+%s+(TODO)") or lines[headline_line]:match("^%*+%s+(NEXT)") or ""
  local priority = lines[headline_line]:match("%[#([ABC])%]") or ""
  local title = data.title
  local new_headline = stars .. " "
  if todo ~= "" then new_headline = new_headline .. todo .. " " end
  if priority ~= "" then new_headline = new_headline .. "[#" .. priority .. "] " end
  new_headline = new_headline .. title
  table.insert(result, new_headline)

  local has_scheduled = false
  local has_props = false
  for i = headline_line + 1, block_end do
    local t = lines[i]:gsub("^%s*(.-)%s*$", "%1")
    if t:match("^SCHEDULED:") or t:match("^DEADLINE:") then
      if data.timestamp then
        table.insert(result, "  SCHEDULED: <" .. data.timestamp .. ">")
        has_scheduled = true
      else
        table.insert(result, lines[i])
      end
    elseif t == ":PROPERTIES:" then
      has_props = true
      table.insert(result, "  :PROPERTIES:")
    elseif t == ":END:" and has_props then
      has_props = false
      table.insert(result, "  :END:")
    elseif has_props then
      if t:match("^:GCAL_ID:") and data.event_id then
        table.insert(result, "  :GCAL_ID: " .. data.event_id)
      elseif t:match("^:GCAL_UPDATED:") and data.updated then
        table.insert(result, "  :GCAL_UPDATED: " .. data.updated)
      elseif t:match("^:LOCATION:") then
        if data.location and data.location ~= "" then
          table.insert(result, "  :LOCATION: " .. data.location)
        end
      elseif t:match("^:CALENDAR_ID:") then
        table.insert(result, "  :CALENDAR_ID: " .. (data.calendar_id or "primary"))
      elseif t:match("^:RECURRING_EVENT_ID:") and data.recurring_event_id then
        table.insert(result, "  :RECURRING_EVENT_ID: " .. data.recurring_event_id)
      elseif t:match("^:RECURRENCE:") and data.recurrence then
        table.insert(result, "  :RECURRENCE: " .. vim.json.encode(data.recurrence))
      else
        table.insert(result, lines[i])
      end
    else
      table.insert(result, lines[i])
    end
  end

  if not has_scheduled and data.timestamp then
    table.insert(result, "  SCHEDULED: <" .. data.timestamp .. ">")
  end

  for i = block_end + 1, #lines do
    table.insert(result, lines[i])
  end

  vim.fn.writefile(result, path)
end

local function append_event_to_import_file(path, data)
  local lines = {
    "* TODO " .. data.title,
    "  SCHEDULED: <" .. data.timestamp .. ">",
    "  :PROPERTIES:",
  }
  if data.event_id then
    table.insert(lines, "  :GCAL_ID: " .. data.event_id)
  end
  if data.calendar_id then
    table.insert(lines, "  :CALENDAR_ID: " .. data.calendar_id)
  end
  if data.location and data.location ~= "" then
    table.insert(lines, "  :LOCATION: " .. data.location)
  end
  if data.updated then
    table.insert(lines, "  :GCAL_UPDATED: " .. data.updated)
  end
  if data.recurring_event_id then
    table.insert(lines, "  :RECURRING_EVENT_ID: " .. data.recurring_event_id)
  end
  if data.recurrence then
    table.insert(lines, "  :RECURRENCE: " .. vim.json.encode(data.recurrence))
  end
  table.insert(lines, "  :END:")
  if data.description and data.description ~= "" then
    table.insert(lines, "")
    vim.list_extend(lines, vim.split("  " .. data.description:gsub("\n", "\n  "), "\n"))
  end
  table.insert(lines, "")

  local existing = {}
  local ok = pcall(function() existing = vim.fn.readfile(path) end)
  for _, l in ipairs(lines) do
    table.insert(existing, l)
  end
  vim.fn.writefile(existing, path)
end

local function init_import_file(path)
  local lines = {
    "#+title: GCal Imports",
    "#+filetags: :gcal:",
    "",
  }
  vim.fn.writefile(lines, path)
end

-- IMPORT ---------------------------------------------------------------------
function M.import_gcal()
  if cfg.show_sync_status then
    dashboard.set_in_progress(true)
  end
  local existing = M.get_existing_roam_events()
  
  local calendars = cfg.calendars or { "primary" }
  local total_imported = 0
  local total_updated = 0
  local total_deleted = 0
  local total_conflicts = 0
  
  -- Use first org dir for imports
  local import_dir = cfg.org_dirs[1] or cfg.agenda_dir
  if not import_dir then
    vim.notify("org-gcal-sync: No org_dirs configured. Please add org_dirs to your setup.", vim.log.levels.ERROR)
    if cfg.show_sync_status then
      dashboard.add_error("No org_dirs configured")
      dashboard.set_in_progress(false)
    end
    return
  end
  local expanded_import_dir = vim.fn.expand(import_dir)
  
  for _, calendar_id in ipairs(calendars) do
    local gcal_events, err = M.get_gcal_events(calendar_id)
    
    if not gcal_events then
      vim.notify("Failed to fetch Google Calendar events from " .. calendar_id .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
      if cfg.show_sync_status then
        dashboard.add_error("Failed to fetch events from calendar: " .. calendar_id)
        dashboard.set_in_progress(false)
      end
      return
    end

    local imported = 0
    local updated = 0

    -- Import new and update existing events
    for key, event in pairs(gcal_events) do
      local existing_event = existing[key]
      
      if not existing_event then
        -- Check if an event with this GCAL_ID already exists anywhere in org dirs
        local event_exists_by_id = false
        if event.id then
          for _, org_event in pairs(existing) do
            if org_event.event_id == event.id then
              existing_event = org_event
              event_exists_by_id = true
              break
            end
          end
        end
        
        if not event_exists_by_id then
          local import_file = cfg.calendar_import_targets and cfg.calendar_import_targets[calendar_id]
          local is_user_target = import_file ~= nil
          if not import_file then
            import_file = expanded_import_dir .. "/" .. import_filename_for_calendar(calendar_id)
          end
          
          if vim.fn.filereadable(import_file) == 0 and not is_user_target then
            init_import_file(import_file)
          end
          local opts = {
            title = event.title,
            timestamp = event.timestamp,
            location = event.location,
            description = event.description,
            event_id = event.id,
            updated = event.updated,
            calendar_id = calendar_id,
            recurring_event_id = event.recurring_event_id,
            recurrence = event.recurrence,
          }
          local ok, lines = pcall(vim.fn.readfile, import_file)
          if not ok then lines = {} end
          local headline = find_headline_by_event_id(lines, event.id)
          
          if headline then
            local success, result = pcall(update_event_in_file, import_file, opts, headline)
            if success then
              updated = updated + 1
            else
              vim.notify('Failed to update event in import file: ' .. tostring(result), vim.log.levels.ERROR)
              if cfg.show_sync_status then
                dashboard.add_error('Failed to update event: ' .. event.title)
              end
            end
          else
            local success, result = pcall(append_event_to_import_file, import_file, opts)
            if success then
              imported = imported + 1
            else
              vim.notify('Failed to import event: ' .. tostring(result), vim.log.levels.ERROR)
              if cfg.show_sync_status then
                dashboard.add_error('Failed to import event: ' .. event.title)
              end
            end
          end
        end
      end
      
      if existing_event and event.updated ~= existing_event.gcal_updated then
        local choice, resolved_event = conflict.resolve_conflict(
          existing_event,
          event,
          cfg.conflict_resolution or "newest"
        )
        
        if choice == "remote" then
          local opts = {
            title = event.title,
            timestamp = event.timestamp,
            location = event.location,
            description = event.description,
            event_id = event.id,
            updated = event.updated,
            calendar_id = calendar_id,
            recurring_event_id = event.recurring_event_id,
            recurrence = event.recurrence,
          }
          local is_import_file = existing_event.path:match("gcal%-imports[^/]*%.org$")
          if not is_import_file then
            for _, target_file in pairs(cfg.calendar_import_targets or {}) do
              if existing_event.path == vim.fn.expand(target_file) then
                is_import_file = true
                break
              end
            end
          end
          if is_import_file then
            local lines = vim.fn.readfile(existing_event.path)
            local headline = find_headline_by_event_id(lines, event.id)
            if headline then
              local success, result = pcall(update_event_in_file, existing_event.path, opts, headline)
              if success then
                updated = updated + 1
              else
                vim.notify('Failed to update event in import file: ' .. tostring(result), vim.log.levels.ERROR)
                if cfg.show_sync_status then
                  dashboard.add_error('Failed to update event: ' .. event.title)
                end
              end
            end
          else
            local success, result = pcall(M.write_roam_event_note, existing_event.path, opts)
            if success then
              updated = updated + 1
            else
              vim.notify('Failed to update roam event: ' .. tostring(result), vim.log.levels.ERROR)
              if cfg.show_sync_status then
                dashboard.add_error('Failed to update event: ' .. event.title)
              end
            end
          end
        elseif choice == "skip" then
          total_conflicts = total_conflicts + 1
        end
      end
      
      existing[key] = nil
    end

    total_imported = total_imported + imported
    total_updated = total_updated + updated
    
    if cfg.show_sync_status then
      dashboard.set_calendar_stats(calendar_id, {
        total = imported + updated,
        last_sync = os.date("%Y-%m-%d %H:%M:%S"),
      })
    end
  end

  -- Build set of protected import files (not to be deleted)
  local protected_import_files = {}
  for _, target_file in pairs(cfg.calendar_import_targets or {}) do
    protected_import_files[vim.fn.expand(target_file)] = true
  end

  -- Delete events that no longer exist in Google Calendar
  local deleted = 0
  for key, event in pairs(existing) do
    if event.event_id and vim.fn.filereadable(event.path) == 1
      and not event.path:match("gcal%-imports[^/]*%.org$")
      and not protected_import_files[event.path] then
      vim.fn.delete(event.path)
      deleted = deleted + 1
    end
  end
  total_deleted = deleted

  if cfg.show_sync_status then
    dashboard.update_stats({
      imported = total_imported,
      updated = total_updated,
      deleted = total_deleted,
      conflicts = total_conflicts,
    })
    dashboard.set_in_progress(false)
  end

  local msg = string.format("Imported: %d, Updated: %d, Deleted: %d, Conflicts: %d", 
    total_imported, total_updated, total_deleted, total_conflicts)
  vim.notify(msg, vim.log.levels.INFO)
  
  -- Show completion
  vim.notify("✓ Import completed", vim.log.levels.INFO)
end

-- EXPORT ---------------------------------------------------------------------
local function parse_org_timestamp(ts_str)
  if not ts_str then return nil, nil end
  
  -- Handle time ranges: <2025-10-30 Thu 11:30 .+1d>--<2025-10-30 Thu 12:30>
  local range_start, range_end = ts_str:match("^<([^>]+)>%-%-%s*<([^>]+)>")
  
  local start_str = range_start or ts_str
  local end_str = range_end
  
  -- Parse start time
  -- Format: 2025-10-30 Thu 10:00 .+1d
  -- or:     2025-10-30 Thu .+1d
  -- or:     2025-10-30
  local year, month, day, hour, min
  
  -- Try: YYYY-MM-DD Day HH:MM (with optional day name and repeater)
  year, month, day, hour, min = start_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)%s+%a+%s+(%d%d):(%d%d)")
  
  if not year then
    -- Try: YYYY-MM-DD HH:MM (without day name)
    year, month, day, hour, min = start_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
  end
  
  if not year then
    -- Try: YYYY-MM-DD Day (date only with day name)
    year, month, day = start_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)%s+%a+")
    hour, min = nil, nil
  end
  
  if not year then
    -- Try: YYYY-MM-DD (date only)
    year, month, day = start_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    hour, min = nil, nil
  end
  
  if not year then return nil, nil end
  
  -- Create start timestamp
  local start_time
  if hour and min then
    local timestamp = os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(min),
    })
    start_time = os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
  else
    -- Date only - construct directly, avoid timezone-induced date shift
    start_time = string.format("%04d-%02d-%02d", tonumber(year), tonumber(month), tonumber(day))
  end
  
  -- Parse end time if exists
  local end_time = nil
  if end_str then
    local end_year, end_month, end_day, end_hour, end_min
    
    -- Try: YYYY-MM-DD Day HH:MM
    end_year, end_month, end_day, end_hour, end_min = end_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)%s+%a+%s+(%d%d):(%d%d)")
    
    if not end_year then
      -- Try: YYYY-MM-DD HH:MM
      end_year, end_month, end_day, end_hour, end_min = end_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
    end
    
    if end_year and end_hour and end_min then
      local end_timestamp = os.time({
        year = tonumber(end_year),
        month = tonumber(end_month),
        day = tonumber(end_day),
        hour = tonumber(end_hour),
        min = tonumber(end_min),
      })
      end_time = os.date("!%Y-%m-%dT%H:%M:%SZ", end_timestamp)
    end
  end
  
  return start_time, end_time
end

local function find_and_clean_gcal_duplicates(calendar_id)
  -- Find duplicate events on Google Calendar side
  local time_min = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 7 * 24 * 60 * 60)
  local time_max = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 90 * 24 * 60 * 60)
  
  local events, err = gcal_api.list_events(time_min, time_max, calendar_id)
  if not events then
    return 0
  end
  
  -- Track events by title+time to find duplicates
  local event_map = {}
  local duplicates = {}
  
  for _, event in ipairs(events) do
    if event.summary and event.start then
      local ts = parse_gcal_datetime(event.start)
      if ts then
        local key = M.make_key(event.summary, ts, nil) -- No event_id for duplicate detection
        
        if event_map[key] then
          -- Found a duplicate - keep the older one (first one we saw)
          table.insert(duplicates, event.id)
        else
          event_map[key] = event.id
        end
      end
    end
  end
  
  -- Delete duplicates
  local deleted = 0
  for _, dup_id in ipairs(duplicates) do
    local success, err = gcal_api.delete_event(dup_id, calendar_id)
    if success then
      deleted = deleted + 1
    else
      vim.notify("Failed to delete duplicate event: " .. (err or "unknown"), vim.log.levels.WARN)
    end
  end
  
  if deleted > 0 then
    vim.notify(string.format("Cleaned up %d duplicate events from Google Calendar", deleted), vim.log.levels.INFO)
  end
  
  return deleted
end

local function update_org_file_with_gcal_id(file_path, gcal_id, gcal_updated, headline_line)
  local lines = vim.fn.readfile(file_path)
  local new_lines = {}
  local in_properties = false
  local properties_exists = false
  local has_gcal_id = false
  
  -- If headline_line given, determine block end (next headline or EOF)
  local block_end
  if headline_line then
    block_end = #lines
    for i = headline_line + 1, #lines do
      if lines[i]:match("^%*+%s") then
        block_end = i - 1
        break
      end
    end
  end
  
  -- Track whether we found the target headline
  local found_headline = false
  
  for i, line in ipairs(lines) do
    local t = line:gsub("^%s*(.-)%s*$", "%1")
    
    if t:match("^%*+%s") then
      if headline_line and i == headline_line then
        found_headline = true
      else
        found_headline = false
      end
    end
    
    -- Only update properties if we're in the target block (or scanning file-wide)
    local in_target = not headline_line or (headline_line and i >= headline_line and i <= block_end)
    
    if in_target or (not headline_line and found_headline) then
      if t == ":PROPERTIES:" then
        in_properties = true
        properties_exists = true
      elseif t == ":END:" and in_properties then
        in_properties = false
        if not has_gcal_id then
          table.insert(new_lines, "  :GCAL_ID: " .. gcal_id)
          if gcal_updated then
            table.insert(new_lines, "  :GCAL_UPDATED: " .. gcal_updated)
          end
        end
      elseif in_properties and t:match("^:GCAL_ID:") then
        has_gcal_id = true
        line = "  :GCAL_ID: " .. gcal_id
      elseif in_properties and t:match("^:GCAL_UPDATED:") and gcal_updated then
        line = "  :GCAL_UPDATED: " .. gcal_updated
      end
    end
    
    table.insert(new_lines, line)
  end
  
  -- If no properties drawer exists, add one after the headline
  local target_line = headline_line or (found_headline and block_end and nil)
  if not properties_exists then
    -- Find target: use headline_line or scan for last headline (backward compat)
    local insert_at = headline_line
    if not insert_at then
      for i = #lines, 1, -1 do
        if lines[i]:match("^%*+%s") then
          insert_at = i
          break
        end
      end
    end
    if insert_at then
      local result = {}
      for i = 1, insert_at do
        table.insert(result, new_lines[i])
      end
      table.insert(result, "  :PROPERTIES:")
      table.insert(result, "  :GCAL_ID: " .. gcal_id)
      if gcal_updated then
        table.insert(result, "  :GCAL_UPDATED: " .. gcal_updated)
      end
      table.insert(result, "  :END:")
      for i = insert_at + 1, #new_lines do
        table.insert(result, new_lines[i])
      end
      new_lines = result
    end
  end
  
  vim.fn.writefile(new_lines, file_path)
end

local function find_and_remove_local_duplicates()
  -- Find and remove duplicate org files (same GCAL_ID)
  if #cfg.org_dirs == 0 then return 0 end
  
  local import_dir = cfg.org_dirs[1]
  local expanded_dir = vim.fn.expand(import_dir)
  local files = vim.fn.globpath(expanded_dir, "**/*.org", false, true)
  files = vim.tbl_filter(function(f) return not f:match("_archive$") end, files)
  
  local seen_ids = {}
  local duplicates = {}
  
  for _, f in ipairs(files) do
    local lines = vim.fn.readfile(f)
    local gcal_id = nil
    local in_properties = false
    
    for _, l in ipairs(lines) do
      local t = l:gsub("^%s*(.-)%s*$", "%1")
      if t == ":PROPERTIES:" then
        in_properties = true
      elseif t == ":END:" then
        in_properties = false
      elseif in_properties and t:match("^:GCAL_ID:") then
        gcal_id = t:match("^:GCAL_ID:%s*(.+)%s*$")
      end
    end
    
    if gcal_id then
      if seen_ids[gcal_id] then
        -- This is a duplicate - mark for deletion
        table.insert(duplicates, f)
      else
        seen_ids[gcal_id] = f
      end
    end
  end
  
  -- Delete duplicates
  for _, dup_file in ipairs(duplicates) do
    vim.fn.delete(dup_file)
  end
  
  if #duplicates > 0 then
    vim.notify(string.format("Removed %d duplicate org files", #duplicates), vim.log.levels.INFO)
  end
  
  return #duplicates
end

function M.export_org()
  if cfg.show_sync_status then
    dashboard.set_in_progress(true)
  end
  
  -- Clean up local duplicate org files first
  find_and_remove_local_duplicates()
  
  -- Clean up duplicates on Google Calendar
  local total_duplicates_cleaned = 0
  for _, calendar_id in ipairs(cfg.calendars or { "primary" }) do
    total_duplicates_cleaned = total_duplicates_cleaned + find_and_clean_gcal_duplicates(calendar_id)
  end
  
  local gcal_events = {}
  local gcal_events_by_id = {}  -- Index by event_id for fast lookup
  
  for _, calendar_id in ipairs(cfg.calendars or { "primary" }) do
    local cal_events = M.get_gcal_events(calendar_id)
    if not cal_events then
      vim.notify("Failed to fetch events from calendar " .. calendar_id .. ", aborting export to prevent data loss", vim.log.levels.ERROR)
      if cfg.show_sync_status then
        dashboard.add_error("Failed to fetch events from calendar: " .. calendar_id)
        dashboard.set_in_progress(false)
      end
      return
    end
    for k, v in pairs(cal_events) do
      gcal_events[k] = v
      if v.id then
        gcal_events_by_id[v.id] = v
      end
    end
  end
  
  local added = 0
  local updated = 0
  local exported = 0
  local tasks_added = 0
  local skipped_existing = 0

  for _, base in ipairs(cfg.org_dirs) do
    local calendar_id = cfg.per_directory_calendars[base] or "primary"
    
    -- Expand path and use globpath for better recursive search
    local expanded_base = vim.fn.expand(base)
    local files = vim.fn.globpath(expanded_base, "**/*.org", false, true)
    files = vim.tbl_filter(function(f) return not f:match("_archive$") end, files)
    
    local total_files = #files
    if total_files > 0 then
      vim.notify(string.format("Scanning %d org files in %s", total_files, expanded_base), vim.log.levels.INFO)
    end
    
    local processed = 0
    for _, f in ipairs(files) do
      local file_calendar_id = calendar_id
      for cal_id, target_file in pairs(cfg.calendar_import_targets or {}) do
        if f == vim.fn.expand(target_file) then
          file_calendar_id = cal_id
          break
        end
      end
      processed = processed + 1
      
      -- Show progress every 20 files
      if processed % 20 == 0 then
        vim.notify(string.format("Processing %d/%d files...", processed, total_files), vim.log.levels.INFO)
      end
      
      local lines = vim.fn.readfile(f)
      
      -- Quick pre-scan: skip files without TODO/NEXT keywords
      local has_todo = false
      for _, l in ipairs(lines) do
        if l:match("^%*+%s+TODO") or l:match("^%*+%s+NEXT") then
          has_todo = true
          break
        end
      end
      
      if not has_todo then
        goto continue
      end
      
      local blocks = split_headline_blocks(lines)
      local gcal_updates = {}

      for _, block in ipairs(blocks) do
        local title, ts, event_id, location, description, is_todo = nil, nil, nil, "", "", false
        local in_properties = false

        for i = block.start, block.finish do
          local l = lines[i]
          local t = l:gsub("^%s*(.-)%s*$", "%1")
          if t:match("^%*+%s+TODO") or t:match("^%*+%s+NEXT") then
            is_todo = true
            local extracted = t:match("^%*+%s+TODO%s+%[#[ABC]%]%s+(.*)")
            if not extracted then
              extracted = t:match("^%*+%s+TODO%s+(.*)")
            end
            if not extracted then
              extracted = t:match("^%*+%s+TODO$") and "" or nil
            end
            if not extracted then
              extracted = t:match("^%*+%s+NEXT%s+%[#[ABC]%]%s+(.*)")
            end
            if not extracted then
              extracted = t:match("^%*+%s+NEXT%s+(.*)")
            end
            if not extracted then
              extracted = t:match("^%*+%s+NEXT$") and "" or nil
            end
            if extracted then
              title = extracted
            end
          elseif t:match("^%*+%s") and not title then
            title = t:match("^%*+%s+(.*)")
          end

          if t:match("SCHEDULED:") or t:match("DEADLINE:") then
            ts = t:match("<([^>]+)>")
          elseif t == ":PROPERTIES:" then
            in_properties = true
          elseif t == ":END:" then
            in_properties = false
          elseif in_properties and t:match("^:GCAL_ID:") then
            event_id = t:match("^:GCAL_ID:%s*(.+)%s*$")
          elseif in_properties and t:match("^:LOCATION:") then
            location = t:match("^:LOCATION:%s*(.+)%s*$") or ""
          elseif not in_properties and not t:match("^[#:]") and not t:match("^%*") and t ~= "" then
            if description ~= "" then description = description .. "\n" end
            description = description .. t:gsub("^%s+", "")
          end
        end

        if is_todo and title and ts then
          local start_time, end_time = parse_org_timestamp(ts)
          if start_time then
            local event_data = { summary = title }

            if start_time:match("^%d%d%d%d%-%d%d%-%d%d$") then
              event_data.start = { date = start_time }
              local year, month, day = start_time:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
              event_data["end"] = { date = next_date_str(start_time) }
            else
              event_data.start = { dateTime = start_time, timeZone = "UTC" }
              if end_time then
                event_data["end"] = { dateTime = end_time, timeZone = "UTC" }
              else
                local year = tonumber(start_time:match("(%d%d%d%d)"))
                local month = tonumber(start_time:match("%d%d%d%d%-(%d%d)"))
                local day = tonumber(start_time:match("%d%d%d%d%-%d%d%-(%d%d)"))
                local hour = tonumber(start_time:match("T(%d%d)"))
                local min = tonumber(start_time:match("T%d%d:(%d%d)"))
                local total_minutes = min + 30
                local add_hours = math.floor(total_minutes / 60)
                local end_min = total_minutes % 60
                local end_hour = hour + add_hours
                if end_hour >= 24 then
                  end_hour = end_hour - 24
                  day = day + 1
                end
                event_data["end"] = {
                  dateTime = string.format("%04d-%02d-%02dT%02d:%02d:00Z", year, month, day, end_hour, end_min),
                  timeZone = "UTC",
                }
              end
            end

            if location and location ~= "" then
              event_data.location = location
            end
            if description and description ~= "" then
              event_data.description = description
            end

            local key = M.make_key(title, ts, event_id)

            if event_id and gcal_events_by_id[event_id] then
              local result, err = gcal_api.update_event(event_id, event_data, file_calendar_id)
              if result then
                updated = updated + 1
                exported = exported + 1
              else
                vim.notify("Failed to update event: " .. (err or "unknown error"), vim.log.levels.WARN)
                if cfg.show_sync_status then
                  dashboard.add_error("Failed to update: " .. title)
                end
              end
            elseif not gcal_events[key] then
              local result, err = gcal_api.create_event(event_data, file_calendar_id)
              if result then
                added = added + 1
                exported = exported + 1
                gcal_events[key] = true
                if result.id then
                  table.insert(gcal_updates, { headline_line = block.start, gcal_id = result.id, updated = result.updated })
                  gcal_events_by_id[result.id] = true
                end
              else
                vim.notify("Failed to create event: " .. (err or "unknown error"), vim.log.levels.WARN)
                if cfg.show_sync_status then
                  dashboard.add_error("Failed to create: " .. title)
                end
              end
            else
              skipped_existing = skipped_existing + 1
            end
          end
        elseif is_todo and title and not ts then
          -- Unscheduled TODOs are local-only; skip Google Tasks (API not used)
        end
      end

      -- Apply all GCAL_ID updates bottom-up for stable line numbers
      table.sort(gcal_updates, function(a, b) return a.headline_line > b.headline_line end)
      for _, u in ipairs(gcal_updates) do
        update_org_file_with_gcal_id(f, u.gcal_id, u.updated, u.headline_line)
      end
      ::continue::
    end
  end

  if cfg.show_sync_status then
    dashboard.update_stats({
      exported = exported,
    })
    dashboard.set_in_progress(false)
  end

  local msg = string.format("Added: %d, Updated: %d, Skipped: %d", 
    added, updated, skipped_existing)
  vim.notify(msg, vim.log.levels.INFO)
  
  -- Show completion
  vim.notify("✓ Export completed", vim.log.levels.INFO)
end

function split_string(input_string, delimiter)
  local result = {}
  local start_index = 1
  local delimiter_start, delimiter_end = string.find(input_string, delimiter, start_index, true)

  while delimiter_start do
    table.insert(result, string.sub(input_string, start_index, delimiter_start - 1))
    start_index = delimiter_end + 1
    delimiter_start, delimiter_end = string.find(input_string, delimiter, start_index, true)
  end

  table.insert(result, string.sub(input_string, start_index))

  return result
end

-- Export a single file
function M.export_single_file(filepath)
  if cfg.show_sync_status then
    dashboard.set_in_progress(true)
  end
  
  -- Clean up any existing duplicates on Google Calendar before processing
  for _, cal_id in ipairs(cfg.calendars or { "primary" }) do
    find_and_clean_gcal_duplicates(cal_id)
  end
  
  local gcal_events = {}
  local gcal_events_by_id = {}
  
  for _, calendar_id in ipairs(cfg.calendars or { "primary" }) do
    local cal_events = M.get_gcal_events(calendar_id)
    if not cal_events then
      vim.notify("Failed to fetch events from calendar " .. calendar_id .. ", aborting single file export to prevent data loss", vim.log.levels.ERROR)
      if cfg.show_sync_status then
        dashboard.add_error("Failed to fetch events from calendar: " .. calendar_id)
        dashboard.set_in_progress(false)
      end
      return
    end
    for k, v in pairs(cal_events) do
      gcal_events[k] = v
      if v.id then
        gcal_events_by_id[v.id] = v
      end
    end
  end
  
  local added = 0
  local updated = 0
  local tasks_added = 0
  
  -- Determine calendar_id based on file location
  local calendar_id = "primary"
  for cal_id, target_file in pairs(cfg.calendar_import_targets or {}) do
    if filepath == vim.fn.expand(target_file) then
      calendar_id = cal_id
      break
    end
  end
  if calendar_id == "primary" then
    for dir, cal_id in pairs(cfg.per_directory_calendars or {}) do
      if filepath:match("^" .. vim.fn.expand(dir)) then
        calendar_id = cal_id
        break
      end
    end
  end
  
  local lines = vim.fn.readfile(filepath)
  
  -- Quick check: skip if no TODO/NEXT
  local has_todo = false
  for _, l in ipairs(lines) do
    if l:match("^%*+%s+TODO") or l:match("^%*+%s+NEXT") then
      has_todo = true
      break
    end
  end
  
  if not has_todo then
    vim.notify("No TODOs found in file, skipping sync", vim.log.levels.INFO)
    return
  end
  
  local blocks = split_headline_blocks(lines)
  local gcal_updates = {}

  for _, block in ipairs(blocks) do
    local title, ts, event_id, location, description, is_todo = nil, nil, nil, "", "", false
    local in_properties = false

    for i = block.start, block.finish do
      local l = lines[i]
      local t = l:gsub("^%s*(.-)%s*$", "%1")

      if t:match("^%*+%s+TODO") or t:match("^%*+%s+NEXT") then
        is_todo = true
        local extracted = t:match("^%*+%s+TODO%s+%[#[ABC]%]%s+(.*)")
        if not extracted then
          extracted = t:match("^%*+%s+TODO%s+(.*)")
        end
        if not extracted then
          extracted = t:match("^%*+%s+TODO$") and "" or nil
        end
        if not extracted then
          extracted = t:match("^%*+%s+NEXT%s+%[#[ABC]%]%s+(.*)")
        end
        if not extracted then
          extracted = t:match("^%*+%s+NEXT%s+(.*)")
        end
        if not extracted then
          extracted = t:match("^%*+%s+NEXT$") and "" or nil
        end
        if extracted then
          title = extracted
        end
      elseif t:match("^%*+%s") and not title then
        title = t:match("^%*+%s+(.*)")
      end

      if t:match("SCHEDULED:") or t:match("DEADLINE:") then
        ts = t:match("<([^>]+)>")
      elseif t == ":PROPERTIES:" then
        in_properties = true
      elseif t == ":END:" then
        in_properties = false
      elseif in_properties and t:match("^:GCAL_ID:") then
        event_id = t:match("^:GCAL_ID:%s*(.+)%s*$")
      elseif in_properties and t:match("^:LOCATION:") then
        location = t:match("^:LOCATION:%s*(.+)%s*$") or ""
      elseif not in_properties and not t:match("^[#:]") and not t:match("^%*") and t ~= "" then
        if description ~= "" then description = description .. "\n" end
        description = description .. t:gsub("^%s+", "")
      end
    end

    if is_todo and title and ts then
      local start_time, end_time = parse_org_timestamp(ts)
      if start_time then
        local event_data = { summary = title }

        if start_time:match("^%d%d%d%d%-%d%d%-%d%d$") then
          event_data.start = { date = start_time }
          local year, month, day = start_time:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
          event_data["end"] = { date = next_date_str(start_time) }
        else
          event_data.start = { dateTime = start_time, timeZone = "UTC" }
          if end_time then
            event_data["end"] = { dateTime = end_time, timeZone = "UTC" }
          else
            local year = tonumber(start_time:match("(%d%d%d%d)"))
            local month = tonumber(start_time:match("%d%d%d%d%-(%d%d)"))
            local day = tonumber(start_time:match("%d%d%d%d%-%d%d%-(%d%d)"))
            local hour = tonumber(start_time:match("T(%d%d)"))
            local min = tonumber(start_time:match("T%d%d:(%d%d)"))
            local total_minutes = min + 30
            local add_hours = math.floor(total_minutes / 60)
            local end_min = total_minutes % 60
            local end_hour = hour + add_hours
            if end_hour >= 24 then
              end_hour = end_hour - 24
              day = day + 1
            end
            event_data["end"] = {
              dateTime = string.format("%04d-%02d-%02dT%02d:%02d:00Z", year, month, day, end_hour, end_min),
              timeZone = "UTC",
            }
          end
        end
        
        if location and location ~= "" then
          event_data.location = location
        end
        if description and description ~= "" then
          event_data.description = description
        end

        if event_id and gcal_events_by_id[event_id] then
          local result, err = gcal_api.update_event(event_id, event_data, calendar_id)
          if result then
            updated = updated + 1
          else
            vim.notify("Failed to update event: " .. (err or "unknown"), vim.log.levels.WARN)
          end
        else
          local key = M.make_key(title, ts, event_id)
          if not gcal_events[key] then
            -- Also scan gcal_events by value (keyed by event ID, not title||ts)
            local found = false
            for _, ev in pairs(gcal_events) do
              if ev.title == title and ev.timestamp == ts then
                found = true
                break
              end
            end
            if not found then
              local result, err = gcal_api.create_event(event_data, calendar_id)
              if result then
                added = added + 1
                gcal_events[key] = true
                if result.id then
                  gcal_events_by_id[result.id] = true
                  table.insert(gcal_updates, { headline_line = block.start, gcal_id = result.id, updated = result.updated })
                end
              else
                vim.notify("Failed to create event: " .. (err or "unknown"), vim.log.levels.WARN)
              end
            end
          end
        end
      end
    elseif is_todo and title and not ts then
      -- Unscheduled TODOs are local-only; skip Google Tasks (API not used)
    end
  end

  -- Apply all GCAL_ID updates bottom-up for stable line numbers
  table.sort(gcal_updates, function(a, b) return a.headline_line > b.headline_line end)
  for _, u in ipairs(gcal_updates) do
    update_org_file_with_gcal_id(filepath, u.gcal_id, u.updated, u.headline_line)
  end
  
  if cfg.show_sync_status then
    dashboard.set_in_progress(false)
  end
  
  local msg = string.format("File sync: Added: %d, Updated: %d, Tasks: %d", added, updated, tasks_added)
  vim.notify(msg, vim.log.levels.INFO)
end

-- Helper to check if sync is already in progress (lock file)
local function is_sync_locked()
  local lock_file = vim.fn.stdpath("data") .. "/org-gcal-sync.lock"
  
  if vim.fn.filereadable(lock_file) == 1 then
    local lock_time = tonumber(vim.fn.readfile(lock_file)[1] or "0")
    local current_time = os.time()
    
    -- If lock is older than 5 minutes, assume it's stale
    if current_time - lock_time > 300 then
      vim.fn.delete(lock_file)
      return false
    end
    
    return true
  end
  
  return false
end

local function create_sync_lock()
  local lock_file = vim.fn.stdpath("data") .. "/org-gcal-sync.lock"
  vim.fn.writefile({tostring(os.time())}, lock_file)
end

local function remove_sync_lock()
  local lock_file = vim.fn.stdpath("data") .. "/org-gcal-sync.lock"
  vim.fn.delete(lock_file)
end

function M.sync()
  -- Check if another instance is already syncing
  if is_sync_locked() then
    vim.notify("⏸️  Sync already in progress in another instance", vim.log.levels.WARN)
    return
  end
  
  -- Run full sync asynchronously
  vim.notify("🔄 Starting full sync (export → import)...", vim.log.levels.INFO)
  create_sync_lock()
  
  vim.schedule(function()
    local success, err = pcall(function()
      M.export_org()
      vim.schedule(function()
        local import_success, import_err = pcall(function()
          M.import_gcal()
        end)
        
        remove_sync_lock()
        
        if import_success then
          vim.notify("✅ Full sync complete!", vim.log.levels.INFO)
        else
          vim.notify("❌ Import failed: " .. tostring(import_err), vim.log.levels.ERROR)
        end
      end)
    end)
    
    if not success then
      remove_sync_lock()
      vim.notify("❌ Export failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

function M.sync_background()
  -- Check if another instance is already syncing
  if is_sync_locked() then
    vim.notify("Skipping background sync - another instance is syncing", vim.log.levels.DEBUG)
    return
  end
  
  -- Background full sync with minimal notifications
  create_sync_lock()
  
  vim.schedule(function()
    local success, err = pcall(function()
      M.export_org()
      vim.schedule(function()
        pcall(function()
          M.import_gcal()
        end)
        remove_sync_lock()
      end)
    end)
    
    if not success then
      remove_sync_lock()
    end
  end)
end

-- Resolve calendar_id for a filepath
local function resolve_calendar_id(filepath)
  for cal_id, target_file in pairs(cfg.calendar_import_targets or {}) do
    if filepath == vim.fn.expand(target_file) then
      return cal_id
    end
  end
  for dir, cal_id in pairs(cfg.per_directory_calendars or {}) do
    if filepath:match("^" .. vim.fn.expand(dir)) then
      return cal_id
    end
  end
  return "primary"
end

-- Delete a single event identified by headline_line in the given lines table.
-- Modifies lines in-place (removes GCAL_ID / GCAL_UPDATED lines).
-- Returns (true, calendar_id, gcal_id) on success, or (false, err_msg) on failure.
local function delete_headline_event(lines, headline_line, filepath)
  local in_properties = false
  local gcal_id, calendar_id = nil, nil
  local gcal_id_ln, gcal_upd_ln = nil, nil

  local block_end = #lines
  for i = headline_line + 1, #lines do
    if lines[i]:match("^%*+%s") then
      block_end = i - 1
      break
    end
  end

  for i = headline_line + 1, block_end do
    local t = lines[i]:gsub("^%s*(.-)%s*$", "%1")
    if t == ":PROPERTIES:" then
      in_properties = true
    elseif t == ":END:" and in_properties then
      break
    elseif in_properties then
      if t:match("^:GCAL_ID:") then
        gcal_id = t:match("^:GCAL_ID:%s*(.+)%s*$")
        gcal_id_ln = i
      elseif t:match("^:GCAL_UPDATED:") then
        gcal_upd_ln = i
      elseif t:match("^:CALENDAR_ID:") then
        calendar_id = t:match("^:CALENDAR_ID:%s*(.+)%s*$")
      end
    end
  end

  if not gcal_id then
    return false, "no GCAL_ID"
  end

  calendar_id = calendar_id or resolve_calendar_id(filepath)

  local result, err = gcal_api.delete_event(gcal_id, calendar_id)
  if not result then
    -- 404 means already gone from calendar — treat as success
    if err and err:find("404") then
      result = true
    else
      return false, err or "unknown error"
    end
  end

  -- Remove GCAL_UPDATED then GCAL_ID lines (bottom-up)
  local to_remove = {}
  if gcal_upd_ln then table.insert(to_remove, gcal_upd_ln) end
  if gcal_id_ln then table.insert(to_remove, gcal_id_ln) end
  table.sort(to_remove, function(a, b) return a > b end)
  for _, ln in ipairs(to_remove) do
    table.remove(lines, ln)
  end

  return true, calendar_id, gcal_id
end

function M.delete_event_by_file(filepath, cursor_line)
  local lines = vim.fn.readfile(filepath)
  if not lines then
    return false, "cannot read file"
  end

  local headline_line = nil
  for i = cursor_line, 1, -1 do
    if lines[i]:match("^%*+%s") then
      headline_line = i
      break
    end
  end

  if not headline_line then
    return false, "no org headline found"
  end

  local ok, cal_or_err, gcal_id = delete_headline_event(lines, headline_line, filepath)
  if not ok then
    return false, cal_or_err
  end

  vim.fn.writefile(lines, filepath)
  return true, cal_or_err
end

function M.delete_current_event()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  local headline_line = nil
  for i = cursor_line, 1, -1 do
    if lines[i]:match("^%*+%s") then
      headline_line = i
      break
    end
  end

  if not headline_line then
    vim.notify("No org headline found at cursor", vim.log.levels.ERROR)
    return
  end

  local ok, cal_or_err, gcal_id = delete_headline_event(lines, headline_line, vim.api.nvim_buf_get_name(bufnr))
  if not ok then
    if cal_or_err ~= "no GCAL_ID" then
      vim.notify("Failed to delete event: " .. cal_or_err, vim.log.levels.ERROR)
    else
      vim.notify("No GCAL_ID found — this headline isn't synced to Google Calendar", vim.log.levels.WARN)
    end
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("write")
  end)

  vim.notify("✓ Deleted from Google Calendar (" .. cal_or_err .. "): " .. gcal_id, vim.log.levels.INFO)
end

function M.batch_delete_events(opts)
  opts = opts or {}
  local filepath = opts.file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local keyword = opts.keyword  -- e.g. "DONE" to filter by todo keyword

  local lines = vim.fn.readfile(filepath)
  if not lines then
    vim.notify("Cannot read file: " .. filepath, vim.log.levels.ERROR)
    return
  end

  local headlines = {}
  for i, l in ipairs(lines) do
    if l:match("^%*+%s") then
      if not keyword or l:match("^%*+%s+" .. keyword) then
        table.insert(headlines, { line = i, text = l })
      end
    end
  end

  if #headlines == 0 then
    vim.notify("No matching headlines found" .. (keyword and " with keyword " .. keyword or ""), vim.log.levels.INFO)
    return
  end

  local deleted = 0
  local failed = 0
  local errors = {}

  -- Process bottom-up so line removals don't shift earlier headline positions
  table.sort(headlines, function(a, b) return a.line > b.line end)

  for _, hl in ipairs(headlines) do
    local ok, cal_or_err = delete_headline_event(lines, hl.line, filepath)
    if ok then
      deleted = deleted + 1
    elseif cal_or_err ~= "no GCAL_ID" then
      failed = failed + 1
      table.insert(errors, hl.text .. ": " .. cal_or_err)
    end
  end

  -- Write back modified lines
  vim.fn.writefile(lines, filepath)

  -- Notify
  local parts = {}
  if deleted > 0 then table.insert(parts, "Deleted: " .. deleted) end
  if failed > 0 then table.insert(parts, "Failed: " .. failed) end
  vim.notify("Batch delete: " .. table.concat(parts, ", "), #errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO)

  for _, err in ipairs(errors) do
    vim.notify("  " .. err, vim.log.levels.WARN)
  end

  -- Refresh buffer if it's open
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == filepath then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("edit!")
      end)
      break
    end
  end
end

function M.strip_gcal_ids(opts)
  opts = opts or {}
  local filepath = opts.file or vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local lines = vim.fn.readfile(filepath)
  if not lines or #lines == 0 then
    vim.notify("Cannot read file or empty: " .. filepath, vim.log.levels.ERROR)
    return
  end

  local new_lines = {}
  local in_properties = false
  local stripped = 0

  for _, line in ipairs(lines) do
    local t = line:gsub("^%s*(.-)%s*$", "%1")
    if t == ":PROPERTIES:" then
      in_properties = true
      table.insert(new_lines, line)
    elseif t == ":END:" and in_properties then
      in_properties = false
      table.insert(new_lines, line)
    elseif in_properties and (t:match("^:GCAL_ID:") or t:match("^:GCAL_UPDATED:")) then
      stripped = stripped + 1
    else
      table.insert(new_lines, line)
    end
  end

  vim.fn.writefile(new_lines, filepath)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == filepath then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("edit!")
      end)
      break
    end
  end

  vim.notify("Stripped " .. stripped .. " GCAL_ID/GCAL_UPDATED from " .. vim.fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
end

return M
