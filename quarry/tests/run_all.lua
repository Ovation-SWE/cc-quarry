-- Runs every tests/test_*.lua file in a fresh subprocess (so a crash
-- in one file cannot corrupt state for another) and prints a summary.
-- Run with: lua tests/run_all.lua   (from the quarry/ directory)

local handle = io.popen("ls tests/test_*.lua 2>/dev/null")
local files = {}
for line in handle:lines() do files[#files + 1] = line end
handle:close()
table.sort(files)

local totalChecks, totalFailures, failedFiles = 0, 0, {}

for _, file in ipairs(files) do
    io.write("=== " .. file .. " ===\n")
    local p = io.popen("lua " .. file .. " 2>&1")
    local output = p:read("a")
    local ok = p:close()
    io.write(output)
    local checks, failures = output:match("(%d+) checks, (%d+) failures")
    if checks then
        totalChecks = totalChecks + tonumber(checks)
        totalFailures = totalFailures + tonumber(failures)
    end
    if not ok then
        failedFiles[#failedFiles + 1] = file
    end
    io.write("\n")
end

print(string.format("TOTAL: %d checks, %d failures across %d files", totalChecks, totalFailures, #files))
if #failedFiles > 0 then
    print("Files that exited with an error: " .. table.concat(failedFiles, ", "))
    os.exit(1)
end
