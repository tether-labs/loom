-- payload.lua
wrk.method = "GET"

response = function(status, headers, body)
  -- Optionally check size
  if string.len(body) < 1024 then
    print("Warning: response smaller than 1KB")
  end
end

