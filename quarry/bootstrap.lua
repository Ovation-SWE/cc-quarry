-- One-command installer for the CC:Tweaked Distributed Quarry system.
--
-- Usage (on any computer/turtle, with the `http` API enabled on the server):
--   wget run https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/bootstrap.lua
--
-- Role is auto-detected: turtles install the worker, plain computers install
-- the master. Pass "worker" or "master" as an argument to override, e.g.:
--   wget run https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/bootstrap.lua master

local BASE_URL = "https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/"

local function fetch(path)
  local url = BASE_URL .. path
  local response, err = http.get(url)
  if not response then
    error(("failed to fetch %s: %s"):format(url, err or "unknown error"))
  end
  local body = response.readAll()
  response.close()
  return body
end

local function writeFile(path, contents)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local handle = fs.open(path, "w")
  handle.write(contents)
  handle.close()
end

if not http then
  error("the `http` API is disabled on this server; see docs/SETUP.md for manual install options")
end

local overrideRole = ...
local role = overrideRole or (turtle and "worker" or "master")
if role ~= "worker" and role ~= "master" then
  error('role must be "worker" or "master", got "' .. tostring(role) .. '"')
end

print("Quarry bootstrap: fetching manifest...")
local manifestFn, loadErr = load(fetch("manifest.lua"))
if not manifestFn then
  error("could not load manifest: " .. tostring(loadErr))
end
local manifest = manifestFn()

print("Installing role: " .. role)

local files = {}
for _, f in ipairs(manifest.common or {}) do table.insert(files, f) end
for _, f in ipairs(manifest[role] or {}) do table.insert(files, f) end

for _, relPath in ipairs(files) do
  local dest = relPath:match("^" .. role .. "/(.+)$") or relPath
  print("  " .. relPath .. " -> " .. dest)
  writeFile(dest, fetch(relPath))
end

print("Install complete. Rebooting in 2 seconds...")
sleep(2)
os.reboot()
