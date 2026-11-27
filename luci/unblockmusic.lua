module("luci.controller.unblockmusic", package.seeall)

function index()
	if not nixio.fs.access("/etc/init.d/unblockmusic") then
		return
	end

	entry({"admin", "services", "unblockmusic"},
		template("unblockmusic/status"), _("音乐解锁"), 55)

	entry({"admin", "services", "unblockmusic", "status"},
		call("act_status")).leaf = true

	entry({"admin", "services", "unblockmusic", "action"},
		call("act_action")).leaf = true
end

function act_status()
	local e = {}
	e.running = (luci.sys.call("pgrep -f '[U]nblockNeteaseMusic' >/dev/null") == 0)
	e.enabled = (luci.sys.call("/etc/init.d/unblockmusic enabled >/dev/null") == 0)
	e.entries = tonumber((luci.sys.exec("ipset list music 2>/dev/null | awk '/Number of entries/{print $4}'") or ""):match("%d+") or "0") or 0

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function act_action()
	if not luci.dispatcher.test_post_security() then
		return
	end

	local act = luci.http.formvalue("act")
	local map = {
		start   = "/etc/init.d/unblockmusic start",
		stop    = "/etc/init.d/unblockmusic stop",
		restart = "/etc/init.d/unblockmusic restart",
		enable  = "/etc/init.d/unblockmusic enable",
		disable = "/etc/init.d/unblockmusic disable"
	}

	local cmd = map[act]
	if cmd then
		luci.sys.call(cmd .. " >/dev/null 2>&1")
	end

	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "unblockmusic"))
end
