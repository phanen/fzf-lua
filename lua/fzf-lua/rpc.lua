---@diagnostic disable-next-line: deprecated
local uv = vim.uv or vim.loop

local _is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

if vim.v.servername and #vim.v.servername > 0 then
  pcall(vim.fn.serverstop, vim.v.servername)
end

---@return string
local function windows_pipename()
  local tmpname = vim.fn.tempname()
  tmpname = string.gsub(tmpname, "\\", "")
  return ([[\\.\pipe\%s]]):format(tmpname)
end

local function new_pipe()
  local tmp = _is_win and windows_pipename() or vim.fn.tempname()
  local socket = assert(uv.new_pipe(false))
  uv.pipe_bind(socket, tmp)
  return socket, tmp
end

-- local function server_listen(server_socket, server_socket_path)
--   uv.listen(server_socket, 10, function(_)
--     local receive_socket = assert(uv.new_pipe(false))
--     uv.accept(server_socket, receive_socket)
--
--     -- Avoid dangling temp dir on premature process kills (live grep)
--     -- see more complete note in spawn.lua
--     if not _is_win then
--       uv.fs_unlink(server_socket_path)
--       local tmpdir = vim.fn.fnamemodify(server_socket_path, ":h")
--       if tmpdir and #tmpdir > 0 then uv.fs_rmdir(tmpdir) end
--     end
--
--     receive_socket:read_start(function(err, data)
--       assert(not err)
--       if not data then
--         uv.close(receive_socket)
--         uv.close(server_socket)
--         -- on windows: ci fail when use uv.stop()
--         -- on linux: zero event can freeze
--         -- https://github.com/ibhagwan/fzf-lua/pull/1955#issuecomment-2785474217
--         -- uv.stop()
--         os.exit(0)
--         return
--       end
--       io.write(data)
--     end)
--   end)
-- end

-- Import LuaJIT FFI
local ffi = require("ffi")
local C = ffi.C

-- Define the C function signatures and constants needed for splice.
-- This only needs to be done once at the top of your file.
ffi.cdef [[
    // ssize_t splice(int fd_in, loff_t *off_in, int fd_out, loff_t *off_out, size_t len, unsigned int flags);
    // loff_t is 64-bit, so we use int64_t* for the offsets. We will pass NULL (nil).
    ssize_t splice(int fd_in, int64_t *off_in, int fd_out, int64_t *off_out, size_t len, unsigned int flags);

    // int pipe(int pipefd[2]);
    int pipe(int pipefd[2]);

    // int close(int fd);
    int close(int fd);
]]

-- splice(2) flags from <fcntl.h>
local SPLICE_F_MOVE = 1 -- Not really needed, but good practice.
local SPLICE_F_MORE = 4 -- A hint to the kernel that more data is coming.

-- Standard I/O file descriptors
local STDOUT_FILENO = 1

-- A reasonably large buffer size for splicing. 64KB is a common choice.
local SPLICE_BUFFER_SIZE = 65536

local function server_listen(server_socket, server_socket_path)
  uv.listen(server_socket, 10, function(_)
    local receive_socket = assert(uv.new_pipe(false))
    uv.accept(server_socket, receive_socket)

    -- Avoid dangling temp dir on premature process kills (live grep)
    if not _is_win then
      uv.fs_unlink(server_socket_path)
      local tmpdir = vim.fn.fnamemodify(server_socket_path, ":h")
      if tmpdir and #tmpdir > 0 then uv.fs_rmdir(tmpdir) end
    end

    -- Get the raw integer file descriptor for the client socket.
    -- This is essential for using it with FFI system calls.
    local socket_fd = receive_socket:fileno()

    -- Create the intermediate pipe required by splice().
    -- pipe_fds[0] is the read end, pipe_fds[1] is the write end.
    local pipe_fds = ffi.new("int[2]")
    if C.pipe(pipe_fds) == -1 then
      -- This is a fatal error, print and close.
      C.perror("pipe")
      uv.close(receive_socket)
      uv.close(server_socket)
      return
    end
    local pipe_read_fd = pipe_fds[0]
    local pipe_write_fd = pipe_fds[1]

    -- Instead of `read_start`, we use a poll handle to wait for the
    -- socket to become readable without blocking the event loop.
    local poll_handle = uv.new_poll(socket_fd)

    local function cleanup()
      poll_handle:stop()
      uv.close(poll_handle)
      uv.close(receive_socket)
      uv.close(server_socket)
      C.close(pipe_read_fd)
      C.close(pipe_write_fd)
      os.exit(0)
    end

    poll_handle:start(uv.UV_READABLE, function(err)
      assert(not err, err)

      while true do
        -- Step 1: Splice data from the socket into our pipe's write-end.
        local bytes_spliced = C.splice(socket_fd, nil, pipe_write_fd, nil, SPLICE_BUFFER_SIZE,
          SPLICE_F_MORE)

        if bytes_spliced < 0 then
          local errno = ffi.errno()
          if errno == ffi.EAGAIN or errno == ffi.EWOULDBLOCK then
            -- The socket buffer is empty for now. Stop looping and wait for
            -- the next poll event.
            break
          else
            -- A real error occurred.
            C.perror("splice (socket -> pipe)")
            cleanup()
            return
          end
        elseif bytes_spliced == 0 then
          -- EOF: The client closed the connection.
          cleanup()
          return
        else
          -- Step 2: Splice the exact number of bytes we just received
          -- from our pipe's read-end to standard output.
          local bytes_written = C.splice(pipe_read_fd, nil, STDOUT_FILENO, nil, bytes_spliced,
            SPLICE_F_MORE)
          if bytes_written < 0 then
            C.perror("splice (pipe -> stdout)")
            cleanup()
            return
          end
        end
      end
    end)
  end)
end

local server_socket, server_socket_path = new_pipe()
server_listen(server_socket, server_socket_path)
---@diagnostic disable-next-line: param-type-mismatch
-- TODO: makes `uv.listen` never return or callback
-- local thread = uv.new_thread(server_listen, server_socket, server_socket_path)
-- io.stdout:write(string.format("thread %s\n", tostring(thread)))

---@class fzf-lua.rpc.Ctx
---@field function_id string An identifier for the RPC function to be executed.
---@field pipe_path string The path to the Unix domain socket for RPC communication.
---@field selection? string[] The selected item(s) (expanded from field expression).
---@field env table<string, string> Environment variables inherited by the RPC process.

---@param opts table
local rpc_nvim_exec_lua = function(opts)
  ---@type fzf-lua.rpc.Ctx
  local ctx = {
    function_id = opts.fnc_id,
    pipe_path = server_socket_path,
    selection = opts.selection,
    env = uv.os_environ(),
  }
  local success, errmsg = pcall(function()
    local chan_id = vim.fn.sockconnect("pipe", opts.fzf_lua_server, { rpc = true })
    vim.rpcrequest(chan_id, "nvim_exec_lua",
      [[return require"fzf-lua.shell".get_func((...).function_id)(...)]], { ctx })
    vim.fn.chanclose(chan_id)
  end)

  if not success or opts.debug == "v" or opts.debug == 2 then
    io.stderr:write(("[DEBUG] debug = %s\n"):format(opts.debug))
    io.stderr:write(("[DEBUG] function ID = %d\n"):format(opts.fnc_id))
    io.stderr:write(("[DEBUG] fzf_lua_server = %s\n"):format(opts.fzf_lua_server))
    for i, v in pairs(_G.arg) do
      io.stderr:write(("[DEBUG] argv[%d] = %s\n"):format(i, v))
    end
    for _, var in ipairs({ "LINES", "COLUMNS" }) do
      io.stderr:write(("[DEBUG] $%s = %s\n"):format(var, os.getenv(var) or "<null>"))
    end
  end

  if not success then
    io.stderr:write(("FzfLua Error: %s\n"):format(errmsg or "<null>"))
    os.exit(1)
  end

  uv.run("once")
  uv.run() -- noreturn, quit by os.exit
end

local args = vim.deepcopy(_G.arg)
args[0] = nil -- remove filename
rpc_nvim_exec_lua({
  fnc_id = tonumber(table.remove(args, 1)),
  debug = (function()
    local ret = table.remove(args, 1)
    if ret == "nil" then
      return nil
    elseif ret == "true" then
      return true
    elseif ret == "false" then
      return false
    else
      return tonumber(ret) or tostring(ret)
    end
  end)(),
  selection = args,
  fzf_lua_server = vim.env.FZF_LUA_SERVER or vim.env.SKIM_FZF_LUA_SERVER or vim.env.NVIM,
})
