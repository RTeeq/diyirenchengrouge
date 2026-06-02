-- ============================================================================
-- SafeZoneSystem.lua — 安全区与出征系统
-- 玩家在安全区内为安全状态；离开安全区开始出征；返回安全区结算奖励
-- ============================================================================

local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")
local GameConfig = require("config.GameConfig")

local SafeZoneSystem = {}

-- 安全区配置（从 GameConfig 读取）
local SAFE_ZONE_CENTER = Vector3(0, 0, 0)
local SAFE_ZONE_RADIUS = 40.0
local SAFE_ZONE_RADIUS_SQ = SAFE_ZONE_RADIUS * SAFE_ZONE_RADIUS

-- 线框可视化
---@type Scene
local scene_ = nil
local wireframeNodes_ = {}   -- 线段节点列表
local wireframeVisible_ = true
local wireframeMat_ = nil    -- 绿色线框材质

-- 出征数据
local expeditionData_ = {
    isOnExpedition = false,
    departureTime = 0,
    killCount = 0,
    goldEarned = 0,
    crystalEarned = 0,
    damageTaken = 0,
}

-- 状态
local wasInSafeZone_ = true
local isInSafeZone_ = true
local declinedSettlement_ = false  -- 拒绝结算后禁止进入安全区
local waitingForDifficulty_ = false  -- 正在等待难度选择

-- 回调
local onExpeditionEnd_ = nil
local onLeaveSafeZone_ = nil      -- 离开安全区回调（弹出难度选择）
local onReturnToSafeZone_ = nil   -- 返回安全区回调（弹出结算确认）
local onPushBack_ = nil           -- 推回回调（设置玩家位置）

-- UI
local summaryPanel_ = nil
local summaryBody_ = nil
local summaryTimer_ = 0
local SUMMARY_DURATION = 5.0

-- ============================================================================
-- 从 GameConfig 同步配置
-- ============================================================================

local function syncFromConfig()
    local cfg = GameConfig.SafeZone
    SAFE_ZONE_CENTER = Vector3(cfg.CenterX, 0, cfg.CenterZ)
    SAFE_ZONE_RADIUS = cfg.Radius
    SAFE_ZONE_RADIUS_SQ = SAFE_ZONE_RADIUS * SAFE_ZONE_RADIUS
end

-- ============================================================================
-- 线框可视化（红色圆圈标记安全区边界）
-- ============================================================================

local function createWireframeMaterial()
    wireframeMat_ = Material:new()
    wireframeMat_:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    wireframeMat_:SetShaderParameter("MatDiffColor", Variant(Color(0.1, 1.0, 0.2, 0.6)))
    wireframeMat_:SetShaderParameter("Roughness", Variant(0.9))
    wireframeMat_:SetShaderParameter("Metallic", Variant(0.0))
end

--- 创建/重建线框节点
local function buildWireframe()
    -- 清除旧节点
    for _, n in ipairs(wireframeNodes_) do
        if n then n:Remove() end
    end
    wireframeNodes_ = {}

    if not scene_ then return end
    if not wireframeMat_ then createWireframeMaterial() end

    local cfg = GameConfig.SafeZone
    local segments = cfg.WireframeSegments or 64
    local radius = SAFE_ZONE_RADIUS
    local cx, cz = SAFE_ZONE_CENTER.x, SAFE_ZONE_CENTER.z
    local y = cfg.WireframeY or 0.3
    local pillarH = 2.0          -- 柱子高度
    local lineThick = 0.15       -- 线段粗细

    -- 用小型拉长 Box 连接相邻点模拟圆环线框
    for i = 0, segments - 1 do
        local a0 = (i / segments) * math.pi * 2
        local a1 = ((i + 1) / segments) * math.pi * 2

        local x0 = cx + math.cos(a0) * radius
        local z0 = cz + math.sin(a0) * radius
        local x1 = cx + math.cos(a1) * radius
        local z1 = cz + math.sin(a1) * radius

        -- 线段中点
        local mx = (x0 + x1) * 0.5
        local mz = (z0 + z1) * 0.5

        -- 线段长度
        local dx = x1 - x0
        local dz = z1 - z0
        local len = math.sqrt(dx * dx + dz * dz)

        -- 方向角（绕 Y 轴）
        local angle = math.atan(dx, dz) * (180.0 / math.pi)

        local node = scene_:CreateChild("__safezone_wire__")
        node.position = Vector3(mx, y, mz)
        node.rotation = Quaternion(angle, Vector3.UP)
        node.scale = Vector3(lineThick, lineThick, len + 0.02)

        local mdl = node:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(wireframeMat_)

        node.enabled = wireframeVisible_
        table.insert(wireframeNodes_, node)
    end

    -- 每隔一定角度放置垂直柱子（标记点）
    local pillarCount = 8
    for i = 0, pillarCount - 1 do
        local a = (i / pillarCount) * math.pi * 2
        local px = cx + math.cos(a) * radius
        local pz = cz + math.sin(a) * radius

        local node = scene_:CreateChild("__safezone_pillar__")
        node.position = Vector3(px, y + pillarH * 0.5, pz)
        node.scale = Vector3(lineThick * 2, pillarH, lineThick * 2)

        local mdl = node:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(wireframeMat_)

        node.enabled = wireframeVisible_
        table.insert(wireframeNodes_, node)
    end

    print("[SafeZone] 线框构建完成, " .. #wireframeNodes_ .. " 个节点, 可见=" .. tostring(wireframeVisible_))
end

--- 切换线框显示
---@return boolean 切换后的状态
function SafeZoneSystem.ToggleWireframe()
    wireframeVisible_ = not wireframeVisible_
    for _, n in ipairs(wireframeNodes_) do
        if n then n.enabled = wireframeVisible_ end
    end
    print("[SafeZone] 线框: " .. (wireframeVisible_ and "显示" or "隐藏"))
    return wireframeVisible_
end

--- 获取线框可见状态
---@return boolean
function SafeZoneSystem.IsWireframeVisible()
    return wireframeVisible_
end

--- 设置线框可见状态
---@param show boolean
function SafeZoneSystem.SetWireframeVisible(show)
    if show == wireframeVisible_ then return end
    SafeZoneSystem.ToggleWireframe()
end

--- 重建线框（配置变更后调用）
function SafeZoneSystem.RebuildWireframe()
    syncFromConfig()
    buildWireframe()
end

-- ============================================================================
-- 安全区判定
-- ============================================================================

---@param pos Vector3
---@return boolean
function SafeZoneSystem.IsInSafeZone(pos)
    local dx = pos.x - SAFE_ZONE_CENTER.x
    local dz = pos.z - SAFE_ZONE_CENTER.z
    return (dx * dx + dz * dz) < SAFE_ZONE_RADIUS_SQ
end

---@param x number
---@param z number
---@return boolean
function SafeZoneSystem.IsPositionInSafeZone(x, z)
    local dx = x - SAFE_ZONE_CENTER.x
    local dz = z - SAFE_ZONE_CENTER.z
    return (dx * dx + dz * dz) < SAFE_ZONE_RADIUS_SQ
end

function SafeZoneSystem.IsPlayerInSafeZone()
    return isInSafeZone_
end

function SafeZoneSystem.IsOnExpedition()
    return expeditionData_.isOnExpedition
end

function SafeZoneSystem.GetRadius()
    return SAFE_ZONE_RADIUS
end

function SafeZoneSystem.GetCenter()
    return SAFE_ZONE_CENTER
end

-- ============================================================================
-- 出征记录
-- ============================================================================

---@param gold number
---@param crystal number
function SafeZoneSystem.RecordKill(gold, crystal)
    if not expeditionData_.isOnExpedition then return end
    expeditionData_.killCount = expeditionData_.killCount + 1
    expeditionData_.goldEarned = expeditionData_.goldEarned + gold
    expeditionData_.crystalEarned = expeditionData_.crystalEarned + (crystal or 0)
end

---@param damage number
function SafeZoneSystem.RecordDamage(damage)
    if not expeditionData_.isOnExpedition then return end
    expeditionData_.damageTaken = expeditionData_.damageTaken + math.floor(damage)
end

-- ============================================================================
-- 出征控制（公开方法）
-- ============================================================================

--- 手动开始出征（由 main.lua 在难度选择完成后调用）
function SafeZoneSystem.StartExpedition()
    expeditionData_.isOnExpedition = true
    expeditionData_.departureTime = os.clock()
    expeditionData_.killCount = 0
    expeditionData_.goldEarned = 0
    expeditionData_.crystalEarned = 0
    expeditionData_.damageTaken = 0
    declinedSettlement_ = false
    waitingForDifficulty_ = false
    print("[SafeZone] 出征开始")
end

--- 获取当前出征数据（供结算UI使用）
---@return table
function SafeZoneSystem.GetExpeditionData()
    return {
        isOnExpedition = expeditionData_.isOnExpedition,
        departureTime = expeditionData_.departureTime,
        killCount = expeditionData_.killCount,
        goldEarned = expeditionData_.goldEarned,
        crystalEarned = expeditionData_.crystalEarned,
        damageTaken = expeditionData_.damageTaken,
    }
end

--- 设置拒绝结算状态
---@param declined boolean
function SafeZoneSystem.SetDeclinedSettlement(declined)
    declinedSettlement_ = declined
    if declined then
        print("[SafeZone] 玩家拒绝结算，禁止进入安全区")
    end
end

-- ============================================================================
-- 出征结算
-- ============================================================================

---@return table summary
function SafeZoneSystem.EndExpedition()
    local duration = os.clock() - expeditionData_.departureTime
    local summary = {
        duration = duration,
        killCount = expeditionData_.killCount,
        goldEarned = expeditionData_.goldEarned,
        crystalEarned = expeditionData_.crystalEarned,
        damageTaken = expeditionData_.damageTaken,
    }
    expeditionData_.isOnExpedition = false
    declinedSettlement_ = false
    print(string.format("[SafeZone] 出征结束: %d击杀, %d金币, %d水晶, %.0f秒",
        summary.killCount, summary.goldEarned, summary.crystalEarned, summary.duration))
    return summary
end

-- ============================================================================
-- 更新（每帧调用）
-- ============================================================================

---@param dt number
---@param playerPos Vector3
function SafeZoneSystem.Update(dt, playerPos)
    wasInSafeZone_ = isInSafeZone_
    isInSafeZone_ = SafeZoneSystem.IsInSafeZone(playerPos)

    -- 未出征时：禁止离开安全区，触碰边界推回 + 弹出难度选择
    if not expeditionData_.isOnExpedition then
        if not isInSafeZone_ then
            -- 推回安全区内（边界内侧）
            local dx = playerPos.x - SAFE_ZONE_CENTER.x
            local dz = playerPos.z - SAFE_ZONE_CENTER.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < 0.1 then dx, dz = 0, 1; dist = 1 end
            local pushDist = SAFE_ZONE_RADIUS - GameConfig.SafeZone.PushBackOffset
            local nx, nz = dx / dist, dz / dist
            local newPos = Vector3(
                SAFE_ZONE_CENTER.x + nx * pushDist,
                playerPos.y,
                SAFE_ZONE_CENTER.z + nz * pushDist
            )
            if onPushBack_ then onPushBack_(newPos) end
            isInSafeZone_ = true

            -- 首次触碰边界，弹出难度选择
            if not waitingForDifficulty_ then
                waitingForDifficulty_ = true
                if onLeaveSafeZone_ then onLeaveSafeZone_() end
            end
        end
    else
        -- 出征中：返回安全区 → 触发结算确认
        if not wasInSafeZone_ and isInSafeZone_ then
            if onReturnToSafeZone_ then
                onReturnToSafeZone_()
            end
        end

        -- 拒绝结算后的边界强制：推回安全区外
        if declinedSettlement_ and isInSafeZone_ then
            local dx = playerPos.x - SAFE_ZONE_CENTER.x
            local dz = playerPos.z - SAFE_ZONE_CENTER.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < 0.1 then dx, dz = 0, 1; dist = 1 end
            local pushDist = SAFE_ZONE_RADIUS + GameConfig.SafeZone.PushBackOffset
            local nx, nz = dx / dist, dz / dist
            local newPos = Vector3(
                SAFE_ZONE_CENTER.x + nx * pushDist,
                playerPos.y,
                SAFE_ZONE_CENTER.z + nz * pushDist
            )
            if onPushBack_ then onPushBack_(newPos) end
            isInSafeZone_ = false
        end
    end

    -- 结算面板自动关闭
    if summaryPanel_ and summaryTimer_ > 0 then
        summaryTimer_ = summaryTimer_ - dt
        if summaryTimer_ <= 0 then
            summaryPanel_:Hide()
        end
    end
end

-- ============================================================================
-- 回调注册
-- ============================================================================

---@param cb function(summary)
function SafeZoneSystem.OnExpeditionEnd(cb)
    onExpeditionEnd_ = cb
end

---@param cb function() 离开安全区时触发
function SafeZoneSystem.OnLeaveSafeZone(cb)
    onLeaveSafeZone_ = cb
end

---@param cb function() 返回安全区时触发
function SafeZoneSystem.OnReturnToSafeZone(cb)
    onReturnToSafeZone_ = cb
end

---@param cb function(newPos: Vector3) 推回回调
function SafeZoneSystem.OnPushBack(cb)
    onPushBack_ = cb
end

-- ============================================================================
-- 结算面板 UI
-- ============================================================================

---@return table panel
function SafeZoneSystem.CreateSummaryPanel()
    summaryPanel_ = UI.Panel {
        id = "expSummaryOverlay",
        position = "absolute",
        top = "30%", left = "50%",
        width = 260,
        marginLeft = -130,
        backgroundColor = { 15, 15, 25, 220 },
        borderRadius = 12,
        borderWidth = 2,
        borderColor = { 100, 180, 255, 150 },
        padding = { 16, 20 },
        alignItems = "center",
        visible = false,
        children = {
            UI.Label {
                text = "出征结算",
                fontSize = 20,
                fontWeight = "bold",
                fontColor = { 255, 220, 80, 255 },
                marginBottom = 12,
            },
            UI.Panel {
                id = "expSumBody",
                width = "100%",
            },
            UI.Button {
                text = "跳过",
                fontSize = 13,
                width = 80,
                height = 30,
                variant = "outline",
                borderRadius = 15,
                marginTop = 14,
                onClick = function()
                    summaryTimer_ = 0
                    if summaryPanel_ then summaryPanel_:Hide() end
                end,
            },
        },
    }
    summaryBody_ = summaryPanel_:FindById("expSumBody")
    return summaryPanel_
end

---@param summary table
function SafeZoneSystem.ShowSummary(summary)
    if not summaryBody_ then return end
    UIHelper.DestroyChildren(summaryBody_)

    local minutes = math.floor(summary.duration / 60)
    local seconds = math.floor(summary.duration % 60)

    local lines = {
        { icon = "⏱", label = "出征时长", value = string.format("%d:%02d", minutes, seconds) },
        { icon = "💀", label = "击杀数",   value = tostring(summary.killCount) },
        { icon = "💰", label = "获得金币", value = "+" .. tostring(summary.goldEarned) },
        { icon = "💎", label = "获得水晶", value = "+" .. tostring(summary.crystalEarned) },
        { icon = "🩸", label = "受到伤害", value = tostring(summary.damageTaken) },
    }

    for _, line in ipairs(lines) do
        summaryBody_:AddChild(UI.Panel {
            flexDirection = "row",
            justifyContent = "space-between",
            width = "100%",
            marginBottom = 6,
            children = {
                UI.Label {
                    text = line.icon .. " " .. line.label,
                    fontSize = 13,
                    fontColor = { 200, 200, 220, 220 },
                },
                UI.Label {
                    text = line.value,
                    fontSize = 13,
                    fontWeight = "bold",
                    fontColor = { 255, 255, 255, 255 },
                },
            },
        })
    end

    summaryPanel_:Show()
    summaryTimer_ = SUMMARY_DURATION
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function SafeZoneSystem.Init(scene)
    scene_ = scene or scene_
    syncFromConfig()
    wasInSafeZone_ = true
    isInSafeZone_ = true
    expeditionData_.isOnExpedition = false
    declinedSettlement_ = false
    waitingForDifficulty_ = false
    summaryTimer_ = 0

    -- 构建线框（初始隐藏）
    if scene_ then
        buildWireframe()
    end

    print("[SafeZone] 安全区系统初始化完成 (半径=" .. SAFE_ZONE_RADIUS .. "m)")
end

function SafeZoneSystem.Reset()
    syncFromConfig()
    wasInSafeZone_ = true
    isInSafeZone_ = true
    expeditionData_.isOnExpedition = false
    expeditionData_.killCount = 0
    expeditionData_.goldEarned = 0
    expeditionData_.crystalEarned = 0
    expeditionData_.damageTaken = 0
    declinedSettlement_ = false
    waitingForDifficulty_ = false
    summaryTimer_ = 0
    if summaryPanel_ then summaryPanel_:Hide() end
    -- 重建线框（保持之前的可见状态）
    if scene_ then buildWireframe() end
end

return SafeZoneSystem
