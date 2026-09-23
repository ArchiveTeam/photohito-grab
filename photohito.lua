local urlparse = require("socket.url")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")
local html_entities = require("htmlEntities")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local item_type = nil
local item_name = nil
local item_value = nil

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false
local status_code = 0
local content_type = ""

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false
local context = {}

local item_patterns = {
  ["^https?://photohito%.com/photo/([0-9]+)[/%?]"] = "photo",
  ["^https?://photohito%.com/photo/orgshow/([0-9]+)[/%?]"] = "photo",
  ["^https?://photohito%.com/user/([0-9]+)[/%?]"] = "user",
  ["^https?://photohito%.com/user/photo/([0-9]+)[/%?]"] = "user",
  ["^https?://photohito%.com/user/profile/([0-9]+)[/%?]"] = "user",
  ["^https?://photohito%.com/user/fan/([0-9]+)[/%?]"] = "user",
  ["^https?://photohito%.com/user/fan/following/([0-9]+)[/%?]"] = "user",
  ["^https?://photohito%.com/user/tag/([0-9]+)/"] = "user",
  ["^https?://photohito%.com/user/gallery/([0-9]+)/list/"] = "user",
  ["^https?://photohito%.com/user/gallery/([0-9]+/[0-9]+)[/%?]"] = "gallery",
  ["^https?://(photohito%.com/uploads/[^#]+)"] = "media",
  ["^https?://(photohito%.com/images/[^#]+)"] = "media",
  ["^https?://(photohito%.com/css/[^#]+)"] = "media",
  ["^https?://(photohito%.com/js/[^#]+)"] = "media",
  ["^https?://(photohito%.com/fonts/[^#]+)"] = "media",
  ["^https?://(photohito%.com/favicon%.ico[^#]*)"] = "media",
  ["^https?://(photohito%.k%-img%.com/[^#]+)"] = "media",
}

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file, "rb"))
    local body = f:read("*all")
    f:close()
    return body
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
    target[item] = true
    return true
  end
  return false
end

percent_encode_url = function(newurl)
  return string.gsub(newurl, "(.)", function(c)
    local b = string.byte(c)
    if b < 32 or b > 126 then
      return string.format("%%%02X", b)
    end
    return c
  end)
end

find_item = function(url)
  for pattern, type_ in pairs(item_patterns) do
    local value = string.match(url, pattern) or string.match(url .. "/", pattern)
    if value then
      if type_ == "user" and string.match(url, "[%?&]p=[0-9]+") then
        type_ = "page"
        value = string.match(url, "^https?://([^#]+)")
      elseif type_ == "media" then
        value = string.gsub(value, "^photohito%.com/uploads/", "photohito.k-img.com/uploads/")
      end
      return {
        ["value"]=percent_encode_url(value),
        ["type"]=type_
      }
    end
  end
  if not string.match(url, "^https?://photohito%.com/api/") then
    local value = string.match(url, "^https?://(photohito%.com/[^#]*)")
    if value then
      return {
        ["value"]=percent_encode_url(value),
        ["type"]="page"
      }
    end
  end
end

finish_item = function()
  if item_name then
    if not abortgrab and context["photo_file"] == false then
      print("No photo found.")
      abort_item()
    end
    if not abortgrab and context["scan"] then
      print("No last page found.")
      abort_item()
    end
  end
end

set_item = function(url)
  if ids[string.lower(url)]
    or (context["scan"] and url == context["scan"]["url"]) then
    return nil
  end
  local found = find_item(url)
  if found then
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_name ~= item_name then
      finish_item()
      ids = {}
      context = {
        ["entry_url"]=url
      }
      item_value = new_item_value
      item_type = new_item_type
      ids[string.lower(url)] = true
      ids[string.lower(urlparse.unescape(item_value))] = true
      abortgrab = false
      tries = 0
      retry_url = false
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parent)
  local lower = string.lower(url)
  if ids[lower]
    or (context["scan"] and url == context["scan"]["url"]) then
    return true
  end

  for _, pattern in pairs({
    "^https?://photohito%.com/api/photolist/",
    "^https?://photohito%.com/user/login/",
    "^https?://photohito%.com/photo/upload/",
    "^https?://[^/]*amazon%-adsystem%.com/",
    "^https?://[^/]*doubleclick%.net/",
    "^https?://[^/]*googletagmanager%.com/",
    "^https?://[^/]*rubiconproject%.com/",
    "^https?://[^/]*s%-onetag%.com/",
    "^https?://[^/]*geoedge%.be/",
    "^https?://assets%.adobedtm%.com/",
    "^https?://[^/]*twitter%.com/intent/",
    "^https?://[^/]*facebook%.com/sharer",
    "^https?://[^/]*w3%.org/2000/svg$"
  }) do
    if string.match(lower, pattern) then
      return false
    end
  end

  local found = find_item(url)
  if found then
    if found["type"] == "media" and item_type ~= "media" then
      local image_url = string.match(found["value"], "^(photohito%.k%-img%.com/uploads/.-)_[tml]%.jpg$")
      if image_url then
        allowed("https://" .. image_url .. "_o.jpg", parent)
      end
    end
    local new_item = found["type"] .. ":" .. found["value"]
    if new_item ~= item_name then
      if found["type"] ~= "photo" then
        discover_item(discovered_items, percent_encode_url(new_item))
      end
      return false
    end
    return true
  end

  if not (
    string.match(lower, "^https?://photohito%.com/")
    or string.match(lower, "^https?://photohito%.k%-img%.com/")
  ) then
    if string.match(lower, "^https?://[^/%.]+/") then
      return false
    end
    discover_item(discovered_outlinks, string.match(percent_encode_url(url), "^([^%s]+)"))
    return false
  end

  if item_type == "photo"
    and string.match(lower, "^https?://photohito%.com/api/photolist/") then
    for identifier in string.gmatch(url, "[%?&]target_id=([0-9]+)") do
      if ids[identifier] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function(s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil

  set_item(url)
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, body_data, force)
    if type(body_data) == "number" then
      body_data = nil
    end
    if not newurl then
      newurl = ""
    end
    newurl = html_entities.decode(decode_codepoint(newurl))
    newurl = string.gsub(newurl, "\\/", "/")
    newurl = string.match(newurl, "^%s*(.-)%s*$")
    newurl = fix_case(newurl)
    if not string.match(newurl, "^https?://") or string.match(newurl, "[%s\\\"<>]") then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = url
    while string.match(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    url_ = percent_encode_url(url_)
    if string.match(url_, "^http://photohito%.com/")
      or string.match(url_, "^http://photohito%.k%-img%.com/") then
      url_ = string.gsub(url_, "^http:", "https:")
    end
    if not body_data and (
      string.match(url_, "^https?://photohito%.com/photo/orgshow/")
      or string.match(url_, "^https?://photohito%.com/user/gallery/[0-9]+/[0-9]+/slideshow/")
    ) then
      return nil
    end
    local key = ((body_data and "POST") or "GET") .. "\0" .. url_ .. "\0" .. (body_data or "")
    if (force or (not processed(key) and (body_data or not processed(url_))))
      and allowed(url_) then
      local url_data = {
        url=url_,
        headers={}
      }
      if body_data then
        url_data["body_data"] = body_data
        url_data["method"] = "POST"
        url_data["headers"]["Content-Type"]="application/x-www-form-urlencoded; charset=UTF-8"
      end
      table.insert(urls, url_data)
      addedtolist[key] = true
      if not body_data then
        addedtolist[url_] = true
        addedtolist[url] = true
      end
      return true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    newurl = string.gsub(newurl, " ", "%%20")
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  if item_type == "media"
    and string.match(url, "^https?://photohito%.k%-img%.com/uploads/.-_m%.jpg$") then
    check(string.gsub(url, "^https?://photohito%.k%-img%.com/", "https://photohito.com/"))
  end

  if allowed(url) and status_code < 300 then
    if string.match(content_type, "^text/")
      or string.match(content_type, "javascript")
      or string.match(content_type, "json")
      or string.match(content_type, "xml") then
      html = read_file(file)
    end

    if string.match(url, "^https?://photohito%.com/api/photoList/%?") then
      json = cjson.decode(html)
      for _, photo in pairs(json["lists"]) do
        check("https://photohito.com/photo/" .. tostring(photo["id"]) .. "/")
        check("https://photohito.com/user/" .. tostring(photo["user_id"]) .. "/")
        check(photo["img_url"])
      end
      html = nil
    elseif html then
      for attributes, options in string.gmatch(html, "<select%s+([^>]+)>(.-)</select>") do
        if string.match(attributes, "id=\"photo%-order%-select\"")
          or string.match(attributes, "id=\"order\"") then
          local order_url = string.match(html, "id=\"order_uri\"[^>]+data%-uri=\"([^\"]+)\"")
            or string.match(url, "^([^%?]+)")
          local parameter = "o"
          if string.match(html, "id=\"sort_value\"%s+value=\"sort_order\"") then
            parameter = "order"
          end
          order_url = order_url .. ((string.match(order_url, "%?") and "&") or "?") .. parameter .. "="
          for order in string.gmatch(options, "<option[^>]+value=\"([^\"]+)\"") do
            check(urlparse.absolute(url, order_url .. order))
          end
        elseif string.match(attributes, "id=\"areaselect\"") then
          for path, area in string.gmatch(options, "<option%s+data%-uri=['\"]([^'\"]+)['\"]%s+value=\"([^\"]+)\"") do
            check(urlparse.absolute(url, path .. area .. "/"))
          end
        end
      end
      if item_type == "user" then
        context["galleries"] = string.match(html, "class=\"number%-of%-gallery\">ギャラリー数：([0-9]+)") or context["galleries"]
      end
      local pagination = string.match(html, "<ul id=[\"']pagination[\"'][^>]*>(.-)</ul>")
      if pagination
        and not context["scan"]
        and string.match(pagination, "class=[\"']current_item[\"']><span>1</span>") then
        local total = string.match(html, "id=\"num_results\">([0-9]+)件")
        local pattern = "class=[\"']photo%-container%-wrapper[%s\"']"
        if string.match(url, "^https?://photohito%.com/user/photo/[0-9]+/") then
          total = string.match(html, "class=\"number%-of%-photo\">写真総数：([0-9]+)枚")
        elseif string.match(url, "^https?://photohito%.com/user/fan/following/[0-9]+/") then
          total = string.match(html, "ファンになってくれている：([0-9]+)人")
          pattern = "class=[\"']fan%-container[%s\"']"
        elseif string.match(url, "^https?://photohito%.com/user/fan/[0-9]+/") then
          total = string.match(html, "ファンになっている：([0-9]+)人")
          pattern = "class=[\"']fan%-container[%s\"']"
        elseif string.match(url, "^https?://photohito%.com/user/gallery/[0-9]+/list/") then
          total = context["galleries"]
          pattern = "class=[\"']user%-block[%s\"']"
        end
        local prefix, suffix = string.match(html_entities.decode(pagination), "href=[\"']([^\"']-[%?&]p=)[0-9]+([^\"']*)")
        if prefix then
          if total then
            local page_size = 0
            for _ in string.gmatch(html, "(" .. pattern .. ")") do
              page_size = page_size + 1
            end
            if page_size > 0 then
              for page = 1, math.ceil(tonumber(total) / page_size) do
                check(urlparse.absolute(url, prefix .. tostring(page) .. suffix))
              end
            end
          elseif item_type == "page" then
            local page = 2
            for number in string.gmatch(html_entities.decode(pagination), "[%?&]p=([0-9]+)") do
              page = math.max(page, tonumber(number))
            end
            context["scan"] = {
              ["url"]=urlparse.absolute(url, prefix .. tostring(page) .. suffix),
              ["lower"]=1,
              ["tries"]=1
            }
            check(context["scan"]["url"], nil, true)
          else
            check(urlparse.absolute(url, prefix .. "1" .. suffix))
          end
        end
      end
      if string.match(url, "^https?://photohito%.com/photo/orgshow/")
        or string.match(url, "^https?://photohito%.com/user/gallery/[0-9]+/[0-9]+/slideshow/") then
        for block in string.gmatch(html, "(<div data%-src=.-</div>)") do
          local photo_id = string.match(block, "<img id=\"img_([0-9]+)\"")
          check("https://photohito.com/photo/" .. photo_id .. "/")
          if item_type == "gallery"
            or photo_id == item_value then
            check(string.match(block, "<img[^>]+src=\"([^\"]+)\""))
          end
          if item_type == "photo"
            and photo_id == item_value then
            check(string.match(block, "data%-src=\"([^\"]+)\""))
            context["photo_file"] = true
          end
        end
        html = string.gsub(html, "<div data%-src=.-</div>", "")
      else
        for attributes, body in string.gmatch(html, "<form%s+([^>]+)>(.-)</form>") do
          local action = string.match(attributes, "action=[\"']([^\"']+)")
          if action and (
            string.match(action, "^/photo/orgshow/[0-9]+/")
            or string.match(action, "^/user/gallery/[0-9]+/[0-9]+/slideshow/")
          ) then
            check(
              urlparse.absolute(url, action),
              "csrf_token=" .. urlparse.escape(string.match(body, "name=[\"']csrf_token[\"']%s+value=[\"']([^\"']+)"))
            )
          end
        end
        if item_type == "photo" and string.match(url, "^https?://photohito%.com/photo/[0-9]+/") then
          context["photo_file"] = false
          for _, direction in pairs({"index", "prev", "next"}) do
            check(
              "https://photohito.com/api/photoList/"
              .. "?photo_list_action=photo_show"
              .. "&target_id=" .. item_value
              .. "&owner_id=" .. string.match(html, "id=\"owner_id\"%s+data%-id=\"([0-9]+)\"")
              .. "&direction=" .. direction
              .. "&photo_size=t"
            )
          end
        end
      end
    end

    if html then
      for quote, quoted in pairs({
        ["\""]=string.gsub(html, "&[qQ][uU][oO][tT];", "\""),
        ["'"]=string.gsub(html, "&#039;", "'")
      }) do
        for newurl in string.gmatch(quoted, "([^" .. quote .. "]+)") do
          checknewurl(newurl)
        end
        for _, attribute in pairs({"href", "src", "data-src"}) do
          for newurl in string.gmatch(html, "[^%-]" .. string.gsub(attribute, "%-", "%%-") .. "=" .. quote .. "([^" .. quote .. "]+)" .. quote) do
            checknewshorturl(newurl)
          end
        end
      end
      for newurl in string.gmatch(html, "[^%-]href=([^\"'%s>]+)") do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(html, "url%(%s*(.-)%s*%)") do
        newurl = string.gsub(html_entities.decode(newurl), "^[\"'](.-)[\"']$", "%1")
        checknewurl(newurl)
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, "<link>(.-)</link>") do
        check(string.match(newurl, "^%s*<!%[CDATA%[(.-)%]%]>%s*$") or newurl)
      end
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  local scan = context["scan"]
  if scan and url == scan["url"] then
    local prefix, page, suffix = string.match(url, "^(.-[%?&]p=)([0-9]+)(.*)$")
    page = tonumber(page)
    if status_code == 200 then
      scan["lower"] = page
    elseif status_code == 404 then
      scan["upper"] = page
    else
      abort_item()
      return urls
    end
    if scan["upper"] and scan["upper"] - scan["lower"] == 1 then
      context["scan"] = nil
      for number = 1, scan["lower"] do
        check(prefix .. tostring(number) .. suffix)
      end
    elseif scan["tries"] == 40 then
      print("No last page found.")
      abort_item()
    else
      page = (scan["upper"] and math.floor((scan["lower"] + scan["upper"]) / 2)) or page * 2
      scan["url"] = prefix .. tostring(page) .. suffix
      scan["tries"] = scan["tries"] + 1
      check(scan["url"], nil, true)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  local headers = http_stat["response_headers"]["headers"]
  status_code = http_stat["statcode"]
  content_type = headers["content-type"] and string.lower(headers["content-type"][1]) or ""
  set_item(url["url"])

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()

  logged_response = true
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    print("Not writing to WARC.")
    return false
  end

  if http_stat["res"] < 0 then
    return false
  end

  if not (
    status_code == 200
    or status_code == 301
    or status_code == 302
    or (
      status_code == 404
      and (url["url"] == context["entry_url"] or item_type == "media" or item_type == "page")
    )
  ) then
    retry_url = true
    return false
  end

  if status_code == 200 then
    if http_stat["len"] == 0
      or (http_stat["contlen"] >= 0 and http_stat["len"] ~= http_stat["contlen"]) then
      retry_url = true
      return false
    end
    if string.match(url["url"], "^https?://photohito%.com/api/photoList/") then
      if cjson.decode(read_file(http_stat["local_file"]))["response_type"] ~= 0 then
        retry_url = true
        return false
      end
    elseif string.match(url["url"], "^https?://photohito%.com/photo/[0-9]+/") then
      local html = read_file(http_stat["local_file"])
      if not string.match(html, "id=\"info_id\"%s+data%-id=\"" .. item_value .. "\"")
        or not string.match(html, "name=[\"']csrf_token[\"']%s+value=[\"'][^\"']+") then
        retry_url = true
        return false
      end
    elseif string.match(url["url"], "^https?://photohito%.com/photo/orgshow/") then
      if not string.match(read_file(http_stat["local_file"]), "<img id=\"img_" .. item_value .. "\"") then
        retry_url = true
        return false
      end
    elseif item_type == "media"
      and (
        string.match(url["url"], "/uploads/photo[0-9]+/")
        or string.match(url["url"], "/thumb%.php%?")
      )
      and not string.match(content_type, "^image/") then
      retry_url = true
      return false
    end
  end

  if status_code >= 300 and status_code <= 399 then
    if not http_stat["newloc"] then
      retry_url = true
      return false
    end
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if string.match(newloc, "[%s\\\"]") or not string.match(newloc, "^https?://") then
      retry_url = true
      return false
    end
  end

  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
    retry_url = true
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  local newloc = nil
  if status_code >= 300 and status_code <= 399 then
    if http_stat["newloc"] then
      newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    end
  end

  if status_code == 0 or http_stat["res"] < 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 5
    if status_code == 403 then
      maxtries = 0
    end
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    downloaded[url["url"]] = true
  end

  if newloc then
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  finish_item()
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = https.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["photohito-607cab925d7cf141"] = discovered_items,
    ["urls-b5512a8984dec2f1"] = discovered_outlinks
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end
