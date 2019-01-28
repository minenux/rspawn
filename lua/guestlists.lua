-- API holder object
rspawn.guestlists = {}

local kick_step = 0

local kick_period = tonumber(minetest.settings:get("rspawn.kick_period")) or 1
local exile_distance = tonumber(minetest.settings:get("rspawn.exile_distance")) or 64

local GUEST_BAN = 0
local GUEST_ALLOW = 1

-- Levvy helpers
-- FIXME Minetest API might actually be able to do this cross-stacks with a single call at inventory level.

local levvy_name = minetest.settings:get("rspawn.levvy_name") or "default:cobble"
local levvy_qtty = tonumber(minetest.settings:get("rspawn.levvy_qtty")) or 10
local levvy_nicename = "cobblestone"

minetest.after(0,function()
    if minetest.registered_items[levvy_name] then
        levvy_nicename = minetest.registered_nodes[levvy_name].description
    else
        minetest.debug("No such item "..levvy_name.." -- reverting to defaults.")
        levvy_name = "default:cobble"
        levvy_qtty = 99
    end
end)

local function find_levvy(player)
    -- return itemstack index, and stack itself, with qtty removed
    -- or none if not found/not enough found
    local i

    if not player then
        minetest.log("action", "Tried to access undefined player")
        return false
    end

    local pname = player:get_player_name()
    local player_inv = minetest.get_inventory({type='player', name = pname})
    local total_count = 0

    if not player_inv then
        minetest.log("action", "Could not access inventory for "..pname)
        return false
    end

    for i = 1,32 do
        local itemstack = player_inv:get_stack('main', i)
        local itemname = itemstack:get_name()
        if itemname == levvy_name then
            if itemstack:get_count() >= levvy_qtty then
                return true
            else
                total_count = total_count + itemstack:get_count()

                if total_count >= (levvy_qtty) then
                    return true
                end
            end
        end
    end

    minetest.chat_send_player(pname, "You do not have enough "..levvy_nicename.." to pay the spawn levvy for your invitation.")
    return false
end

function rspawn:consume_levvy(player)
    if not player then
        minetest.log("action", "Tried to access undefined player")
        return false
    end

    local i
    local pname = player:get_player_name()
    local player_inv = minetest.get_inventory({type='player', name = pname})
    local total_count = 0

    -- TODO combine find_levvy and consume_levvy so that we're
    --    not scouring the inventory twice...
    if find_levvy(player) then
        for i = 1,32 do
            local itemstack = player_inv:get_stack('main', i)
            local itemname = itemstack:get_name()
            if itemname == levvy_name then
                if itemstack:get_count() >= levvy_qtty then
                    itemstack:take_item(levvy_qtty)
                    player_inv:set_stack('main', i, itemstack)
                    return true
                else
                    total_count = total_count + itemstack:get_count()
                    itemstack:clear()
                    player_inv:set_stack('main', i, itemstack)

                    if total_count >= (levvy_qtty) then
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- Visitation rights check

local function canvisit(hostname, guestname)
    local host_glist = rspawn.playerspawns["guest lists"][hostname] or {}
    local global_glist = rspawn.playerspawns["town lists"] or {}

    return (
        -- Host has specific guest entry and guest is not banned
        (host_glist[guestname] and (host_glist[guestname] == GUEST_BAN or host_glist[guestname] == GUEST_TOWNBAN)) or
        -- Host is global host
        (not host_glist[guestname] and global_glist[hostname])
    )
end

-- Operational functions (to be invoked by /command)

function rspawn.guestlists:addplayer(hostname, guestname)
    local guestlist = rspawn.playerspawns["guest lists"][hostname] or {}

    if guestlist[guestname] ~= nil then
        if guestlist[guestname] == GUEST_BAN then
            minetest.chat_send_player(guestname, hostname.." let you back into their spawn.")
        end
        guestlist[guestname] = GUEST_ALLOW

    elseif rspawn:consume_levvy(minetest.get_player_by_name(hostname) ) then -- Automatically notifies host if they don't have enough
        guestlist[guestname] = GUEST_ALLOW
        minetest.chat_send_player(guestname, hostname.." added you to their spawn! You can now visit them with /spawn visit "..hostname)
    else
        return
    end
    
    minetest.chat_send_player(hostname, guestname.." is allowed to visit your spawn.")
    rspawn.playerspawns["guest lists"][hostname] = guestlist
    rspawn:spawnsave()
end

function rspawn.guestlists:exileplayer(hostname, guestname)
    local guestlist = rspawn.playerspawns["guest lists"][hostname] or {}

    if guestlist[guestname] == GUEST_ALLOW then
        guestlist[guestname] = GUEST_BAN
        rspawn.playerspawns["guest lists"][hostname] = guestlist

    else
        minetest.chat_send_player(hostname, guestname.." is not in your accepted guests list.")
        return
    end

    minetest.chat_send_player(guestname, hostname.." banishes you!")
    rspawn:spawnsave()
end

function rspawn.guestlists:listguests(hostname)
    local guests = ""
    local guestlist = rspawn.playerspawns["guest lists"][hostname] or {}

    local global_hosts = rspawn.playerspawns["town lists"] or {}
    if global_hosts[hostname] then
        guests = ", You are an active town host."
    end

    for guestname,status in pairs(guestlist) do
        if status == GUEST_ALLOW then status = "" else status = " (exiled)" end

        guests = guests..", "..guestname..status
    end

    if guests == "" then
        guests = ", No guests, not hosting a town."
    end

    minetest.chat_send_player(hostname, guests:sub(3))
end

function rspawn.guestlists:listhosts(guestname)
    local hosts = ""

    for hostname,hostguestlist in pairs(rspawn.playerspawns["guest lists"]) do
        for gname,status in pairs(hostguestlist) do
            if guestname == gname then
                if status == GUEST_ALLOWED then
                    hosts = hosts..", "..hostname
                end
            end
        end
    end

    local global_hostlist = rspawn.playerspawns["town lists"]
    for _,hostname in ipairs(global_hostlist) do
        if global_hostlist[hostname]["town status"] == "on" and
          global_hostlist[hostname][guestname] ~= GUEST_BAN
          then
            hosts = hosts..", "..hostname
        end
    end

    if hosts == "" then
        hosts = ", (no visitable hosts)"
    end

    minetest.chat_send_player(guestname, hosts:sub(3))
end

function rspawn.guestlists:visitplayer(hostname, guestname)
    local guest = minetest.get_player_by_name(guestname)
    local hostpos = rspawn.playerspawns[hostname]

    if not hostpos then
        minetest.log("error", "[rspawn] Missing spawn position data for "..hostname)
        minetest.chat_send_player(guestname, "Could not find spawn position for "..hostname)
    end

    if guest and canvisit(hostname, guestname) then
        guest:setpos(hostpos)
    else
        minetest.chat_send_player(guestname, "Could not visit "..hostname)
    end
end

function rspawn.guestlists:townset(hostname, params)
    params = params:split(" ")

    local mode = params[1]
    local guestname = params[2]
    local global_glist = rspawn.playerspawns["town lists"] or {}
    local town_banlist = global_glist[hostname] or {}

    if mode == "open" then
        town_banlist["town status"] = "on"
        minetest.chat_send_all(hostname.." is opened as a town!")

    elseif mode == "close" then
        town_banlist["town status"] = "off"
        minetest.chat_send_all(hostname.." is not currently a town - only guests may directly visit.")

    elseif mode == "ban" and guestname then
        town_banlist[guestname] = GUEST_BAN
        minetest.chat_send_all(guestname.." is exiled from "..hostname.."'s town.")

    elseif mode == "unban" and guestname then
        town_banlist[guestname] = nil
        minetest.chat_send_all(guestname.." is no longer exiled from  "..hostname.."'s town.")

    else
        minetest.chat_send_player(hostname, "Unknown parameterless town operation: "..mode)
        return
    end

    global_glist[hostname] = town_banlist
    rspawn.playerspawns["town lists"] = global_glist

    rspawn:spawnsave()
end

-- Exile check
minetest.register_globalstep(function(dtime)
    if kick_step < kick_period then
        kick_step = kick_step + dtime
        return
    else
        kick_step = 0
    end

    for _,guest in ipairs(minetest.get_connected_players()) do
        local guestpos = guest:getpos()
        local guestname = guest:get_player_name()

        for _,player_list_name in ipairs({"guest lists", "town lists"}) do
            for hostname,host_guestlist in pairs(rspawn.playesrpawns[player_list_name]) do

                if host_guestlist[guestname] == GUEST_BAN then
                    local vdist = vector.distance(guestpos, rspawn.playerspawns[hostname])

                    if vdist < exile_distance then
                        guest:setpos(rspawn.playerspawns[guestname])
                        minetest.chat_send_player(guestname, "You got too close to "..hostname.."'s turf.")
                        return

                    elseif vdist < exile_distance*1.5 then
                        minetest.chat_send_player(guestname, "You are getting too close to "..hostname.."'s turf.")
                        return
                    end
                end
            end
        end

    end
end)
