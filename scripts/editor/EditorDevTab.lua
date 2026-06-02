-- ============================================================================
-- EditorDevTab.lua -- 开发者调试面板（全屏单页版）
-- 所有内容合并为一个 ScrollView，利用全屏宽度多列布局
-- ============================================================================

local GameConfig = require("config.GameConfig")
local PlayerHealth = require("combat.PlayerHealth")
local LevelSystem = require("combat.LevelSystem")
local EnemyManager = require("combat.EnemyManager")
local EquipmentSystem = require("combat.EquipmentSystem")
local KillBonusSystem = require("combat.KillBonusSystem")
local DroneCamera = require("core.DroneCamera")
local WeaponSystem = require("combat.WeaponSystem")
local DebugCollision = require("debug.DebugCollision")
local SafeZoneSystem = require("world.SafeZoneSystem")
local FirstPersonController = require("core.FirstPersonController")
local HUD = require("ui.HUD")
local GameManager = require("core.GameManager")
local AwakeningSystem = require("systems.AwakeningSystem")
local UI = require("urhox-libs/UI")

local EditorDevTab = {}

-- ============================================================================
-- 配置修改记录
-- ============================================================================

--- 记录所有被修改过的配置项 { {label=string, oldVal=number, newVal=number}, ... }
local changeLog_ = {}

--- 注册所有配置输入框，用于保存前主动 flush
--- { {label=string, tbl=table, key=string, getInput=function} }
local pendingInputs_ = {}

--- 记录一条修改（同时保存表引用和键名，用于持久化保存）
---@param label string 显示标签
---@param oldVal number 修改前的值
---@param newVal number 修改后的值
---@param tbl table 所属配置表引用
---@param key string 配置键名
local function recordChange(label, oldVal, newVal, tbl, key)
    -- 如果已有同名记录，更新 newVal（保留最初的 oldVal）
    for _, entry in ipairs(changeLog_) do
        if entry.label == label then
            entry.newVal = newVal
            return
        end
    end
    table.insert(changeLog_, { label = label, oldVal = oldVal, newVal = newVal, tbl = tbl, key = key })
end

--- 获取所有修改记录
function EditorDevTab.GetChanges()
    return changeLog_
end

--- 清空修改记录
function EditorDevTab.ClearChanges()
    changeLog_ = {}
end

-- ============================================================================
-- 配置持久化：将开发者面板修改保存为默认值
-- ============================================================================

local OVERRIDES_FILE = "config-overrides.json"

--- 通过表引用反查 GameConfig 中的路径（最多3层）
--- 例如 GameConfig.Player → {"Player"}, GameConfig.Enemies.Melee → {"Enemies","Melee"}
---@param target table 要查找的表引用
---@return string[]|nil 路径数组，找不到返回 nil
local function findTablePath(target)
    if target == GameConfig then return {} end
    for k1, v1 in pairs(GameConfig) do
        if type(v1) == "table" then
            if v1 == target then return { k1 } end
            for k2, v2 in pairs(v1) do
                if type(v2) == "table" then
                    if v2 == target then return { k1, k2 } end
                    for k3, v3 in pairs(v2) do
                        if type(v3) == "table" and v3 == target then
                            return { k1, k2, k3 }
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- 将 changeLog_ 中的修改保存到 config-overrides.json（运行时覆盖）
--- 同时确保 GameConfig 内存值已更新
---@return boolean 是否保存成功
---@return number 保存的条目数
local function saveConfigOverrides()
    if #changeLog_ == 0 then return false, 0 end

    -- 先读取已有的覆盖文件（合并追加）
    local existing = {}
    if fileSystem:FileExists(OVERRIDES_FILE) then
        local rf = File(OVERRIDES_FILE, FILE_READ)
        if rf:IsOpen() then
            local ok, data = pcall(cjson.decode, rf:ReadString())
            rf:Close()
            if ok and type(data) == "table" then
                existing = data
            end
        end
    end

    -- 将 changeLog_ 中的修改合并到 existing
    local count = 0
    for _, entry in ipairs(changeLog_) do
        if entry.tbl and entry.key then
            local path = findTablePath(entry.tbl)
            if path then
                table.insert(path, entry.key)
                local pathKey = table.concat(path, ".")
                existing[pathKey] = entry.newVal
                count = count + 1
                print("[EditorDevTab] 记录修改: " .. pathKey .. " = " .. tostring(entry.newVal))
            else
                print("[EditorDevTab] 警告: 找不到表路径 key=" .. entry.key)
            end
        end
    end

    if count == 0 then return false, 0 end

    -- 写入覆盖文件
    local wf = File(OVERRIDES_FILE, FILE_WRITE)
    if not wf:IsOpen() then
        print("[EditorDevTab] 无法写入 " .. OVERRIDES_FILE)
        return false, 0
    end
    wf:WriteString(cjson.encode(existing))
    wf:Close()

    print("[EditorDevTab] 已保存 " .. count .. " 项到 " .. OVERRIDES_FILE)
    return true, count
end

---@type Scene
local scene_ = nil
local fpController_ = nil

-- ============================================================================
-- 配置同步：修改 GameConfig 后立即刷新对应的游戏系统
-- ============================================================================

local function syncConfigToGame()
    -- 1. 玩家子系统
    PlayerHealth.ApplyConfig()
    LevelSystem.ApplyConfig()
    FirstPersonController.ApplyConfig()

    -- 2. 物理世界重力
    if scene_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then
            pw:SetGravity(Vector3(0, GameConfig.Player.Gravity, 0))
        end
    end

    -- 3. 相机 FOV
    if fpController_ then
        local camNode = fpController_:GetCameraNode()
        if camNode then
            local cam = camNode:GetComponent("Camera")
            if cam then cam.fov = GameConfig.Camera.FOV end
        end
    end
end

--- 保存前主动读取所有注册的配置输入框，将未提交的修改 flush 到 changeLog_
local function flushPendingInputs()
    print("[EditorDevTab] flushPendingInputs: " .. #pendingInputs_ .. " 个注册输入框")
    for _, entry in ipairs(pendingInputs_) do
        local inputWidget = entry.getInput()
        if inputWidget then
            local v = inputWidget:GetValue()
            local num = tonumber(v)
            local curVal = entry.tbl[entry.key]
            if num and num ~= curVal then
                print("[EditorDevTab] flush 发现修改: " .. entry.label .. " " .. tostring(curVal) .. " → " .. tostring(num))
                entry.tbl[entry.key] = num
                recordChange(entry.label, curVal, num, entry.tbl, entry.key)
            end
        else
            print("[EditorDevTab] flush 警告: " .. entry.label .. " 输入框为 nil")
        end
    end
    print("[EditorDevTab] flush 完成, changeLog_ 有 " .. #changeLog_ .. " 条记录")
    syncConfigToGame()
end

-- 开发者状态
local godMode_ = false
local speedMult_ = 1.0

-- ============================================================================
-- UI 引用（状态监控）
-- ============================================================================
local godModeLabel_, hpLabel_, levelLabel_, enemyLabel_, killLabel_
local speedLabel_, posLabel_, gameTimeLabel_

-- 战斗/增益
local weaponLabel_, dmgMultLabel_, cdMultLabel_, rangeMultLabel_, moveMultLabel_
local orbRangeLabel2_, frenzyLabel_, shieldLabel_, burnLabel_, killTierLabel_, passiveLabel_

-- 等级属性
local lvlCdLabel_, lvlRangeLabel_, lvlHPLabel_, lvlHitLabel_, lvlSizeLabel_, lvlCountLabel_

-- 装备加成
local eqDmgLabel_, eqCdLabel_, eqMoveLabel_, eqRangeLabel_, eqHPLabel_, eqDemonLabel_

-- 渲染/场景
local fpsLabel_, batchLabel_, primLabel_, nodeCountLabel_, monLvLabel_, bossLabel_

-- 原始的 TakeDamage 函数引用（用于无敌模式）
local origTakeDamage_ = nil
local origTakeDamageRaw_ = nil

-- ============================================================================
-- 配色常量
-- ============================================================================

local BTN_BG        = { 50, 60, 85, 255 }
local BTN_HOVER     = { 65, 80, 110, 255 }
local DANGER_BG     = { 120, 35, 35, 255 }
local DANGER_HOVER  = { 160, 50, 50, 255 }
local SUCCESS_BG    = { 35, 100, 55, 255 }
local SUCCESS_HOVER = { 45, 130, 70, 255 }
local SECTION_BG    = { 28, 28, 38, 200 }
local TEXT_COLOR    = { 200, 200, 210, 255 }
local DIM_COLOR     = { 140, 140, 155, 255 }
local LABEL_COLOR   = { 160, 170, 200, 255 }

local STAT_FONT     = 12
local STAT_PAD      = 3
local ACCENT_CYAN   = { 100, 210, 240, 255 }
local ACCENT_GRN    = { 100, 220, 140, 255 }
local ACCENT_YEL    = { 240, 210, 100, 255 }
local ACCENT_RED    = { 240, 120, 100, 255 }
local ACCENT_PUR    = { 180, 140, 255, 255 }
local ROW_BG        = { 22, 24, 34, 180 }

-- ============================================================================
-- 状态刷新
-- ============================================================================

local function refreshStatus()
    if hpLabel_ then
        hpLabel_:SetText(string.format("%.0f / %.0f", PlayerHealth.GetHP(), PlayerHealth.GetMaxHP()))
    end
    if levelLabel_ then
        levelLabel_:SetText(string.format("Lv.%d  %d/%d",
            LevelSystem.GetLevel(), LevelSystem.GetXP(), LevelSystem.GetXPToNext()))
    end
    if enemyLabel_ then
        local count = 0
        for _ in pairs(EnemyManager.GetAllEnemies()) do count = count + 1 end
        enemyLabel_:SetText(tostring(count))
    end
    if killLabel_ then killLabel_:SetText(string.format("%d", EnemyManager.GetKillCount())) end
    if godModeLabel_ then godModeLabel_:SetText(godMode_ and "ON" or "OFF") end
    if speedLabel_ then speedLabel_:SetText(string.format("%.1fx", speedMult_)) end
    if posLabel_ and fpController_ then
        local p = fpController_:GetPosition()
        posLabel_:SetText(string.format("%.0f, %.0f, %.0f", p.x, p.y, p.z))
    end
    if gameTimeLabel_ then
        local t = HUD.GetGameTime()
        gameTimeLabel_:SetText(string.format("%02d:%02d", math.floor(t / 60), math.floor(t % 60)))
    end

    -- 战斗
    if weaponLabel_ then
        local rId = WeaponSystem.GetRightHandWeaponId()
        local lId = WeaponSystem.GetLeftHandWeaponId()
        weaponLabel_:SetText(string.format("%s | %s", rId or "无", lId or "无"))
    end
    if dmgMultLabel_ then dmgMultLabel_:SetText(string.format("%.2fx", EquipmentSystem.GetDamageMult())) end
    if cdMultLabel_ then
        local cd = LevelSystem.GetCooldownMult() * EquipmentSystem.GetCooldownMult() * KillBonusSystem.GetCooldownMult()
        cdMultLabel_:SetText(string.format("%.0f%%", cd * 100))
    end
    if rangeMultLabel_ then
        local r = LevelSystem.GetRangeMult() * EquipmentSystem.GetRangeMult() * KillBonusSystem.GetRangeMult()
        rangeMultLabel_:SetText(string.format("%.0f%%", r * 100))
    end
    if moveMultLabel_ then moveMultLabel_:SetText(string.format("%.0f%%", EquipmentSystem.GetMoveSpeedMult() * 100)) end
    if orbRangeLabel2_ then
        local tier = KillBonusSystem.GetOrbRangeTier()
        local mult = KillBonusSystem.GetOrbRangeMult()
        orbRangeLabel2_:SetText(string.format("+%d%% (Tier %d)", math.floor((mult - 1) * 100), tier))
    end

    -- Buff
    if frenzyLabel_ then
        if KillBonusSystem.IsKillFrenzyActive() then
            frenzyLabel_:SetText(string.format("%.1fs", KillBonusSystem.GetFrenzyTimeLeft()))
        else frenzyLabel_:SetText("未激活") end
    end
    if shieldLabel_ then shieldLabel_:SetText(PlayerHealth.IsShielded() and "有" or "无") end
    if burnLabel_ then burnLabel_:SetText(PlayerHealth.IsBurning() and "是" or "否") end
    if killTierLabel_ then killTierLabel_:SetText(tostring(KillBonusSystem.GetKillTier())) end
    if passiveLabel_ then
        local skills = KillBonusSystem.GetPassiveSkills()
        local names = {}
        for _, s in ipairs(skills) do table.insert(names, s.name or s.id) end
        passiveLabel_:SetText(#names > 0 and table.concat(names, ", ") or "无")
    end

    -- 等级属性
    if lvlCdLabel_ then lvlCdLabel_:SetText(string.format("%.0f%%", LevelSystem.GetCooldownMult() * 100)) end
    if lvlRangeLabel_ then lvlRangeLabel_:SetText(string.format("%.0f%%", LevelSystem.GetRangeMult() * 100)) end
    if lvlHPLabel_ then lvlHPLabel_:SetText(string.format("+%.0f", LevelSystem.GetMaxHPBonus())) end
    if lvlHitLabel_ then lvlHitLabel_:SetText(string.format("+%d", LevelSystem.GetExtraHitCount())) end
    if lvlSizeLabel_ then lvlSizeLabel_:SetText(string.format("%.0f%%", LevelSystem.GetAttackSizeMult() * 100)) end
    if lvlCountLabel_ then lvlCountLabel_:SetText(string.format("+%d", LevelSystem.GetAttackCountBonus())) end

    -- 装备
    if eqDmgLabel_ then eqDmgLabel_:SetText(string.format("%.2fx", EquipmentSystem.GetDamageMult())) end
    if eqCdLabel_ then eqCdLabel_:SetText(string.format("%.0f%%", EquipmentSystem.GetCooldownMult() * 100)) end
    if eqMoveLabel_ then eqMoveLabel_:SetText(string.format("%.0f%%", EquipmentSystem.GetMoveSpeedMult() * 100)) end
    if eqRangeLabel_ then eqRangeLabel_:SetText(string.format("%.0f%%", EquipmentSystem.GetRangeMult() * 100)) end
    if eqHPLabel_ then eqHPLabel_:SetText(string.format("+%.0f", EquipmentSystem.GetMaxHPBonus())) end
    if eqDemonLabel_ then eqDemonLabel_:SetText(EquipmentSystem.IsDemonRageActive() and "激活" or "未激活") end

    -- 渲染
    if fpsLabel_ then
        fpsLabel_:SetText(string.format("%.0f", time:GetFramesPerSecond()))
    end
    if batchLabel_ then batchLabel_:SetText(tostring(renderer.numBatches)) end
    if primLabel_ then primLabel_:SetText(tostring(renderer.numPrimitives)) end
    if nodeCountLabel_ and scene_ then nodeCountLabel_:SetText(tostring(scene_:GetNumChildren(true))) end
    if monLvLabel_ then monLvLabel_:SetText(tostring(EnemyManager.GetMonsterLevel())) end
    if bossLabel_ then
        local bt = EnemyManager.GetActiveBossType()
        bossLabel_:SetText(bt and bt or "无")
    end
end

-- ============================================================================
-- 无敌模式
-- ============================================================================

local function toggleGodMode()
    godMode_ = not godMode_
    if godMode_ then
        if not origTakeDamage_ then
            origTakeDamage_ = PlayerHealth.TakeDamage
            origTakeDamageRaw_ = PlayerHealth.TakeDamageRaw
        end
        PlayerHealth.TakeDamage = function() end
        PlayerHealth.TakeDamageRaw = function() end
        PlayerHealth.Heal(PlayerHealth.GetMaxHP())
        UI.Toast.Show("无敌模式 ON", { variant = "success", duration = 1 })
    else
        if origTakeDamage_ then
            PlayerHealth.TakeDamage = origTakeDamage_
            PlayerHealth.TakeDamageRaw = origTakeDamageRaw_
        end
        UI.Toast.Show("无敌模式 OFF", { variant = "warning", duration = 1 })
    end
    refreshStatus()
end

-- ============================================================================
-- UI 构建辅助
-- ============================================================================

local function makeBtn(text, bg, hover, onClick)
    return UI.Button {
        text = text, fontSize = 11, fontWeight = "bold",
        backgroundColor = bg, hoverBackgroundColor = hover,
        textColor = { 230, 230, 240, 255 }, borderRadius = 4,
        paddingHorizontal = 8, paddingVertical = 5,
        marginRight = 4, marginBottom = 4,
        onClick = function(self) onClick() end,
    }
end

local function makeSmallBtn(text, bg, hover, onClick)
    return UI.Button {
        text = text, fontSize = 10,
        backgroundColor = bg, hoverBackgroundColor = hover,
        textColor = { 220, 220, 230, 255 }, borderRadius = 3,
        paddingHorizontal = 6, paddingVertical = 3,
        marginRight = 3, marginBottom = 3,
        onClick = function(self) onClick() end,
    }
end

--- 数据行：标签 + 值
local function statRow(label, valLabel)
    return UI.Panel {
        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
        backgroundColor = ROW_BG, borderRadius = 3,
        paddingHorizontal = 8, paddingVertical = STAT_PAD, marginBottom = 2,
        children = {
            UI.Label { text = label, fontSize = STAT_FONT, fontColor = DIM_COLOR },
            valLabel,
        },
    }
end

--- 小标题
local function makeSubLabel(text)
    return UI.Label { text = text, fontSize = 11, fontWeight = "bold", fontColor = LABEL_COLOR, marginTop = 4, marginBottom = 3 }
end

--- 可折叠分组
local function makeCollapsible(title, children, startOpen)
    local collapsed = not startOpen
    local contentPanel = UI.Panel {
        flexDirection = "column", visible = not collapsed,
        children = children,
    }
    local arrowLabel = UI.Label {
        text = collapsed and "▶" or "▼",
        fontSize = 9, fontColor = LABEL_COLOR, marginRight = 4,
    }
    return UI.Panel {
        backgroundColor = SECTION_BG, borderRadius = 5,
        padding = 7, marginBottom = 5,
        children = {
            UI.Button {
                flexDirection = "row",
                backgroundColor = { 0, 0, 0, 0 },
                hoverBackgroundColor = { 40, 45, 60, 255 },
                borderRadius = 3, paddingHorizontal = 4, paddingVertical = 2,
                marginBottom = 3,
                onClick = function(self)
                    collapsed = not collapsed
                    if collapsed then contentPanel:Hide(); arrowLabel:SetText("▶")
                    else contentPanel:Show(); arrowLabel:SetText("▼") end
                end,
                children = {
                    arrowLabel,
                    UI.Label { text = title, fontSize = 11, fontWeight = "bold", fontColor = LABEL_COLOR },
                },
            },
            contentPanel,
        },
    }
end

--- 数值编辑行: [标签] [输入框] [✓]
--- silent=true 时不显示 ✓ 按钮和逐条 Toast（用于配置行，统一由"保存为默认值"保存）
--- inputStore: 可选表，传入时会将 getInput 函数存入，用于外部获取输入框引用
local function makeFieldRow(label, currentVal, onApply, silent, inputStore)
    local inputRef = nil
    local oldValStr = tostring(currentVal)
    local function doApply()
        if inputRef then
            local v = inputRef:GetValue()
            if v == oldValStr then return end  -- 值未变化，跳过
            onApply(v)
            oldValStr = v  -- 更新旧值为当前值，便于连续修改
            if not silent then
                UI.Toast.Show("修改成功: " .. label .. "  " .. oldValStr .. " → " .. v, { variant = "success", duration = 1.5 })
            end
        end
    end

    local fieldChildren = {
        UI.Label { text = label, fontSize = 10, fontColor = DIM_COLOR, width = 95, flexShrink = 0 },
        UI.TextField {
            value = tostring(currentVal), fontSize = 10,
            flex = 1, height = 20,
            backgroundColor = { 18, 18, 25, 255 },
            borderColor = { 50, 50, 65, 255 }, borderWidth = 1, borderRadius = 3,
            paddingHorizontal = 4,
            onSubmit = function(self, v)
                if v == oldValStr then return end
                onApply(v)
                oldValStr = v
                if not silent then
                    UI.Toast.Show("修改成功: " .. label .. "  " .. oldValStr .. " → " .. v, { variant = "success", duration = 1.5 })
                end
            end,
            onBlur = function(self)
                doApply()
            end,
            ref = function(w) inputRef = w end,
        },
    }

    -- 非静默模式保留 ✓ 按钮（运行时状态字段）
    if not silent then
        table.insert(fieldChildren, UI.Button {
            text = "✓", fontSize = 9, width = 20, height = 20,
            paddingHorizontal = 0, paddingVertical = 0,
            backgroundColor = { 40, 75, 55, 255 }, hoverBackgroundColor = { 50, 100, 70, 255 },
            textColor = { 200, 255, 200, 255 }, borderRadius = 3, marginLeft = 2,
            onClick = function(self) doApply() end,
        })
    end

    -- 暴露 inputRef getter 给外部（用于保存前 flush）
    if inputStore then
        inputStore.getInput = function() return inputRef end
    end

    return UI.Panel {
        flexDirection = "row", alignItems = "center", marginBottom = 2,
        children = fieldChildren,
    }
end

--- 配置表数值编辑行（失焦自动同步到游戏系统 + 记录修改，统一由"保存为默认值"持久化）
local function makeConfigRow(label, tbl, key)
    local store = {}
    local panel = makeFieldRow(label, tbl[key], function(v)
        local num = tonumber(v)
        if num then
            local oldVal = tbl[key]
            tbl[key] = num
            recordChange(label, oldVal, num, tbl, key)
            syncConfigToGame()
            refreshStatus()
        end
    end, true, store)

    -- 注册到 pendingInputs_，保存前可主动 flush
    table.insert(pendingInputs_, {
        label = label,
        tbl = tbl,
        key = key,
        getInput = store.getInput,
    })

    return panel
end

-- ============================================================================
-- 分区构建函数
-- ============================================================================

--- 分区标题（大标题，用于分隔各个板块）
local function sectionTitle(text)
    return UI.Panel {
        paddingVertical = 6, paddingHorizontal = 4, marginBottom = 4, marginTop = 8,
        borderBottomWidth = 1, borderColor = { 60, 60, 80, 255 },
        children = {
            UI.Label { text = text, fontSize = 14, fontWeight = "bold", fontColor = { 200, 200, 220, 255 } },
        },
    }
end

-- ── 状态监控区 ──
local function buildStatusSection()
    hpLabel_        = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_RED }
    levelLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_CYAN }
    killLabel_      = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    posLabel_       = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = DIM_COLOR }
    godModeLabel_   = UI.Label { text = "OFF", fontSize = STAT_FONT, fontColor = DIM_COLOR }
    speedLabel_     = UI.Label { text = "1.0x", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    enemyLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_YEL }
    gameTimeLabel_  = UI.Label { text = "00:00", fontSize = STAT_FONT, fontColor = TEXT_COLOR }

    weaponLabel_    = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    dmgMultLabel_   = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_RED }
    cdMultLabel_    = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_CYAN }
    rangeMultLabel_ = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_GRN }
    moveMultLabel_  = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_GRN }
    orbRangeLabel2_ = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_PUR }

    frenzyLabel_    = UI.Label { text = "未激活", fontSize = STAT_FONT, fontColor = DIM_COLOR }
    shieldLabel_    = UI.Label { text = "无", fontSize = STAT_FONT, fontColor = DIM_COLOR }
    burnLabel_      = UI.Label { text = "否", fontSize = STAT_FONT, fontColor = DIM_COLOR }
    killTierLabel_  = UI.Label { text = "0", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    passiveLabel_   = UI.Label { text = "无", fontSize = STAT_FONT, fontColor = DIM_COLOR }

    lvlCdLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_CYAN }
    lvlRangeLabel_  = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_GRN }
    lvlHPLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_RED }
    lvlHitLabel_    = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    lvlSizeLabel_   = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    lvlCountLabel_  = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }

    eqDmgLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_RED }
    eqCdLabel_      = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_CYAN }
    eqMoveLabel_    = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_GRN }
    eqRangeLabel_   = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_GRN }
    eqHPLabel_      = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_RED }
    eqDemonLabel_   = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_PUR }

    fpsLabel_       = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_GRN }
    batchLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    primLabel_      = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    nodeCountLabel_ = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = TEXT_COLOR }
    monLvLabel_     = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_YEL }
    bossLabel_      = UI.Label { text = "--", fontSize = STAT_FONT, fontColor = ACCENT_RED }

    -- 左列：基础 + 战斗 + Buff
    local leftCol = UI.Panel {
        flex = 1, marginRight = 4,
        children = {
            makeCollapsible("基础状态", {
                statRow("HP", hpLabel_),
                statRow("等级/经验", levelLabel_),
                statRow("击杀", killLabel_),
                statRow("坐标", posLabel_),
                statRow("无敌", godModeLabel_),
                statRow("移速倍率", speedLabel_),
                statRow("场上敌人", enemyLabel_),
                statRow("游戏时间", gameTimeLabel_),
            }, true),
            makeCollapsible("战斗数据", {
                statRow("武器", weaponLabel_),
                statRow("攻击倍率", dmgMultLabel_),
                statRow("冷却", cdMultLabel_),
                statRow("攻击范围", rangeMultLabel_),
                statRow("移速加成", moveMultLabel_),
                statRow("拾取范围", orbRangeLabel2_),
            }, true),
            makeCollapsible("增益/状态", {
                statRow("狂暴", frenzyLabel_),
                statRow("护盾", shieldLabel_),
                statRow("灼烧", burnLabel_),
                statRow("击杀层级", killTierLabel_),
                statRow("被动技能", passiveLabel_),
            }, true),
        },
    }

    -- 右列：等级属性 + 装备加成 + 渲染
    local rightCol = UI.Panel {
        flex = 1, marginLeft = 4,
        children = {
            makeCollapsible("等级属性", {
                statRow("冷却缩减", lvlCdLabel_),
                statRow("范围加成", lvlRangeLabel_),
                statRow("生命加成", lvlHPLabel_),
                statRow("额外命中", lvlHitLabel_),
                statRow("攻击体积", lvlSizeLabel_),
                statRow("额外弹量", lvlCountLabel_),
            }, true),
            makeCollapsible("装备加成", {
                statRow("伤害倍率", eqDmgLabel_),
                statRow("冷却缩减", eqCdLabel_),
                statRow("移速加成", eqMoveLabel_),
                statRow("范围加成", eqRangeLabel_),
                statRow("生命加成", eqHPLabel_),
                statRow("魔化狂暴", eqDemonLabel_),
            }, true),
            makeCollapsible("渲染/场景", {
                statRow("FPS", fpsLabel_),
                statRow("Draw Batches", batchLabel_),
                statRow("Primitives", primLabel_),
                statRow("场景节点数", nodeCountLabel_),
                statRow("怪物等级", monLvLabel_),
                statRow("当前Boss", bossLabel_),
            }, true),
        },
    }

    return UI.Panel {
        children = {
            sectionTitle("状态监控"),
            UI.Panel {
                flexDirection = "row", marginBottom = 4,
                children = { leftCol, rightCol },
            },
            UI.Panel {
                flexDirection = "row", gap = 4, marginBottom = 4,
                children = { makeSmallBtn("刷新", BTN_BG, BTN_HOVER, refreshStatus) },
            },
        },
    }
end

-- ── 快捷操作区 ──
local function buildQuickActions()
    local collisionBtnLabel_ = nil
    return UI.Panel {
        children = {
            sectionTitle("快捷操作"),
            -- 玩家
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    makeBtn("无敌", SUCCESS_BG, SUCCESS_HOVER, toggleGodMode),
                    makeBtn("满血", SUCCESS_BG, SUCCESS_HOVER, function()
                        PlayerHealth.Heal(PlayerHealth.GetMaxHP()); refreshStatus()
                    end),
                    makeBtn("+1级", BTN_BG, BTN_HOVER, function()
                        LevelSystem.AddXP(LevelSystem.GetXPToNext()); refreshStatus()
                    end),
                    makeBtn("+10级", BTN_BG, BTN_HOVER, function()
                        for i = 1, 10 do LevelSystem.AddXP(LevelSystem.GetXPToNext()) end; refreshStatus()
                    end),
                    makeBtn("清怪", DANGER_BG, DANGER_HOVER, function()
                        local allE = EnemyManager.GetAllEnemies()
                        local c = 0
                        for id in pairs(allE) do EnemyManager.DamageEnemy(id, 999999); c = c + 1 end
                        UI.Toast.Show("清除 " .. c .. " 个", { variant = "warning", duration = 1 }); refreshStatus()
                    end),
                    makeBtn("冻结30s", BTN_BG, BTN_HOVER, function()
                        EnemyManager.FreezeEnemies(fpController_:GetPosition(), 9999, 30)
                    end),
                    makeBtn("刷龙Boss", DANGER_BG, DANGER_HOVER, function()
                        EnemyManager.SpawnDragonBoss(fpController_:GetPosition(), LevelSystem.GetLevel()); refreshStatus()
                    end),
                    makeBtn("刷终极Boss", DANGER_BG, DANGER_HOVER, function()
                        EnemyManager.SpawnUltimateBoss(fpController_:GetPosition()); refreshStatus()
                    end),
                },
            },
            -- 移速
            makeSubLabel("移动速度"),
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    makeSmallBtn("0.5x", BTN_BG, BTN_HOVER, function() speedMult_ = 0.5; fpController_:SetSpeedMult(speedMult_); refreshStatus() end),
                    makeSmallBtn("1x", BTN_BG, BTN_HOVER, function() speedMult_ = 1.0; fpController_:SetSpeedMult(speedMult_); refreshStatus() end),
                    makeSmallBtn("2x", BTN_BG, BTN_HOVER, function() speedMult_ = 2.0; fpController_:SetSpeedMult(speedMult_); refreshStatus() end),
                    makeSmallBtn("5x", BTN_BG, BTN_HOVER, function() speedMult_ = 5.0; fpController_:SetSpeedMult(speedMult_); refreshStatus() end),
                    makeSmallBtn("10x", BTN_BG, BTN_HOVER, function() speedMult_ = 10.0; fpController_:SetSpeedMult(speedMult_); refreshStatus() end),
                },
            },
            -- 传送
            makeSubLabel("传送/视角"),
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    makeSmallBtn("出生点", BTN_BG, BTN_HOVER, function()
                        local sp = GameConfig.Player.StartPosition
                        fpController_:SetPosition(Vector3(sp.x, sp.y, sp.z)); refreshStatus()
                    end),
                    makeSmallBtn("中心", BTN_BG, BTN_HOVER, function()
                        fpController_:SetPosition(Vector3(0, 5, 0)); refreshStatus()
                    end),
                    makeSmallBtn("高空", BTN_BG, BTN_HOVER, function()
                        local p = fpController_:GetPosition()
                        fpController_:SetPosition(Vector3(p.x, 100, p.z)); refreshStatus()
                    end),
                    makeBtn("无人机(L)", BTN_BG, BTN_HOVER, function()
                        local GameEditor = require("editor.GameEditor")
                        GameEditor.Close(); DroneCamera.Toggle(fpController_)
                    end),
                },
            },
            -- 金币 / 水晶 / 觉醒点
            makeSubLabel("🪙 金币 / 🔮 水晶 / ✨ 觉醒点"),
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    makeSmallBtn("🪙+100", SUCCESS_BG, SUCCESS_HOVER, function()
                        GameManager.AddGold(100)
                        UI.Toast.Show("金币 +100 (总: " .. GameManager.GetGold() .. ")", { variant = "success", duration = 1 })
                    end),
                    makeSmallBtn("🪙+1000", SUCCESS_BG, SUCCESS_HOVER, function()
                        GameManager.AddGold(1000)
                        UI.Toast.Show("金币 +1000 (总: " .. GameManager.GetGold() .. ")", { variant = "success", duration = 1 })
                    end),
                    makeSmallBtn("🪙-100", DANGER_BG, DANGER_HOVER, function()
                        GameManager.AddGold(-100)
                        UI.Toast.Show("金币 -100 (总: " .. GameManager.GetGold() .. ")", { variant = "warning", duration = 1 })
                    end),
                    makeSmallBtn("🪙=0", DANGER_BG, DANGER_HOVER, function()
                        GameManager.AddGold(-GameManager.GetGold())
                        UI.Toast.Show("金币已清零", { variant = "warning", duration = 1 })
                    end),
                },
            },
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    makeSmallBtn("🔮+50", SUCCESS_BG, SUCCESS_HOVER, function()
                        GameManager.AddCrystal(50)
                        UI.Toast.Show("水晶 +50 (总: " .. GameManager.GetCrystal() .. ")", { variant = "success", duration = 1 })
                    end),
                    makeSmallBtn("🔮+500", SUCCESS_BG, SUCCESS_HOVER, function()
                        GameManager.AddCrystal(500)
                        UI.Toast.Show("水晶 +500 (总: " .. GameManager.GetCrystal() .. ")", { variant = "success", duration = 1 })
                    end),
                    makeSmallBtn("🔮-50", DANGER_BG, DANGER_HOVER, function()
                        GameManager.AddCrystal(-50)
                        UI.Toast.Show("水晶 -50 (总: " .. GameManager.GetCrystal() .. ")", { variant = "warning", duration = 1 })
                    end),
                    makeSmallBtn("🔮=0", DANGER_BG, DANGER_HOVER, function()
                        GameManager.AddCrystal(-GameManager.GetCrystal())
                        UI.Toast.Show("水晶已清零", { variant = "warning", duration = 1 })
                    end),
                },
            },
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    makeSmallBtn("✨+10", SUCCESS_BG, SUCCESS_HOVER, function()
                        AwakeningSystem.AddPoints(10)
                        UI.Toast.Show("觉醒点 +10 (总: " .. AwakeningSystem.GetPoints() .. ")", { variant = "success", duration = 1 })
                    end),
                    makeSmallBtn("✨+100", SUCCESS_BG, SUCCESS_HOVER, function()
                        AwakeningSystem.AddPoints(100)
                        UI.Toast.Show("觉醒点 +100 (总: " .. AwakeningSystem.GetPoints() .. ")", { variant = "success", duration = 1 })
                    end),
                    makeSmallBtn("✨+1000", SUCCESS_BG, SUCCESS_HOVER, function()
                        AwakeningSystem.AddPoints(1000)
                        UI.Toast.Show("觉醒点 +1000 (总: " .. AwakeningSystem.GetPoints() .. ")", { variant = "success", duration = 1 })
                    end),
                },
            },
            -- 游戏时间
            makeSubLabel("游戏时间"),
            makeFieldRow("设置(秒)", math.floor(HUD.GetGameTime()), function(v)
                local n = tonumber(v); if n then HUD.SetGameTime(n); refreshStatus() end
            end),
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginTop = 4, marginBottom = 4,
                children = {
                    makeSmallBtn("+30s", BTN_BG, BTN_HOVER, function() HUD.SetGameTime(HUD.GetGameTime() + 30); refreshStatus() end),
                    makeSmallBtn("+1m", BTN_BG, BTN_HOVER, function() HUD.SetGameTime(HUD.GetGameTime() + 60); refreshStatus() end),
                    makeSmallBtn("+5m", BTN_BG, BTN_HOVER, function() HUD.SetGameTime(HUD.GetGameTime() + 300); refreshStatus() end),
                    makeSmallBtn("+10m", BTN_BG, BTN_HOVER, function() HUD.SetGameTime(HUD.GetGameTime() + 600); refreshStatus() end),
                    makeSmallBtn("归零", DANGER_BG, DANGER_HOVER, function() HUD.SetGameTime(0); refreshStatus() end),
                },
            },
            -- 调试工具
            makeSubLabel("调试工具"),
            UI.Panel {
                flexDirection = "row", flexWrap = "wrap", gap = 4, marginBottom = 4,
                children = {
                    (function()
                        local btn = makeBtn(
                            "碰撞体: 隐藏",
                            BTN_BG, BTN_HOVER,
                            function()
                                local show = DebugCollision.Toggle()
                                if collisionBtnLabel_ then
                                    collisionBtnLabel_:SetText("碰撞体: " .. (show and "显示" or "隐藏"))
                                end
                            end
                        )
                        collisionBtnLabel_ = btn
                        return btn
                    end)(),
                    makeBtn("重新扫描", BTN_BG, BTN_HOVER, function()
                        local wasVisible = DebugCollision.IsVisible()
                        DebugCollision.Scan()
                        if wasVisible then DebugCollision.SetVisible(true) end
                        UI.Toast.Show("扫描到 " .. DebugCollision.GetCount() .. " 个碰撞体", { duration = 1 })
                    end),
                    (function()
                        local szBtnLabel_ = nil
                        local btn = makeBtn(
                            "安全区线框: 隐藏",
                            BTN_BG, BTN_HOVER,
                            function()
                                local show = SafeZoneSystem.ToggleWireframe()
                                if szBtnLabel_ then
                                    szBtnLabel_:SetText("安全区线框: " .. (show and "显示" or "隐藏"))
                                end
                            end
                        )
                        szBtnLabel_ = btn
                        return btn
                    end)(),
                },
            },
        },
    }
end

-- ── 安全区配置区 ──
local function buildSafeZoneConfig()
    local SZ = GameConfig.SafeZone

    return UI.Panel {
        children = {
            sectionTitle("安全区"),
            UI.Panel {
                flexDirection = "row",
                children = {
                    UI.Panel {
                        flex = 1, marginRight = 4,
                        children = {
                            makeCollapsible("安全区参数", {
                                makeConfigRow("半径(m)", SZ, "Radius"),
                                makeConfigRow("中心X", SZ, "CenterX"),
                                makeConfigRow("中心Z", SZ, "CenterZ"),
                                makeConfigRow("推回偏移(m)", SZ, "PushBackOffset"),
                            }, true),
                        },
                    },
                    UI.Panel {
                        flex = 1, marginLeft = 4,
                        children = {
                            makeCollapsible("线框显示", {
                                makeConfigRow("线框高度Y", SZ, "WireframeY"),
                                makeConfigRow("线框分段数", SZ, "WireframeSegments"),
                                makeBtn("应用并重建线框", SUCCESS_BG, SUCCESS_HOVER, function()
                                    SafeZoneSystem.RebuildWireframe()
                                    -- 如果线框可见，保持可见
                                    if SafeZoneSystem.IsWireframeVisible() then
                                        SafeZoneSystem.SetWireframeVisible(true)
                                    end
                                    UI.Toast.Show("安全区线框已重建 (半径=" .. GameConfig.SafeZone.Radius .. "m)", { variant = "success", duration = 1.5 })
                                end),
                            }, true),
                        },
                    },
                },
            },
        },
    }
end

-- ── 玩家配置区 ──
local function buildPlayerConfig()
    local P = GameConfig.Player
    local C = GameConfig.Combat
    local KN = GameConfig.Knockback

    local leftCol = UI.Panel {
        flex = 1, marginRight = 4,
        children = {
            -- 运行时
            makeCollapsible("运行时状态", {
                makeFieldRow("玩家等级", LevelSystem.GetLevel(), function(v)
                    local n = tonumber(v); if n then LevelSystem.SetLevel(n); refreshStatus() end
                end),
                makeFieldRow("击杀数", EnemyManager.GetKillCount(), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetKillCount(n); refreshStatus() end
                end),
                makeFieldRow("怪物等级", EnemyManager.GetMonsterLevel(), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetMonsterLevel(n); refreshStatus() end
                end),
                makeSubLabel("波次计时器(秒)"),
                makeFieldRow("小波", string.format("%.1f", EnemyManager.GetTimers().smallWave or 0), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetTimers({ smallWave = n }) end
                end),
                makeFieldRow("大波", string.format("%.1f", EnemyManager.GetTimers().bigWave or 0), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetTimers({ bigWave = n }) end
                end),
                makeFieldRow("升级", string.format("%.1f", EnemyManager.GetTimers().upgrade or 0), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetTimers({ upgrade = n }) end
                end),
                makeFieldRow("Boss", string.format("%.1f", EnemyManager.GetTimers().boss or 0), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetTimers({ boss = n }) end
                end),
                makeFieldRow("终极Boss", string.format("%.1f", EnemyManager.GetTimers().ultimate or 0), function(v)
                    local n = tonumber(v); if n then EnemyManager.SetTimers({ ultimate = n }) end
                end),
            }, true),
            -- 属性加成
            makeCollapsible("属性加成", {
                makeFieldRow("攻速", LevelSystem.GetBonuses().attackSpeed or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("attackSpeed", n) end end),
                makeFieldRow("最大HP", LevelSystem.GetBonuses().maxHP or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("maxHP", n) end end),
                makeFieldRow("冷却", LevelSystem.GetBonuses().cooldown or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("cooldown", n) end end),
                makeFieldRow("范围", LevelSystem.GetBonuses().range or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("range", n) end end),
                makeFieldRow("多重", LevelSystem.GetBonuses().count or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("count", n) end end),
                makeFieldRow("攻击大小", LevelSystem.GetBonuses().attackSize or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("attackSize", n) end end),
                makeFieldRow("攻击次数", LevelSystem.GetBonuses().attackCount or 0, function(v)
                    local n = tonumber(v); if n then LevelSystem.SetBonus("attackCount", n) end end),
            }, true),
        },
    }

    local rightCol = UI.Panel {
        flex = 1, marginLeft = 4,
        children = {
            makeCollapsible("玩家配置", {
                makeConfigRow("移动速度(cm/s)", P, "MoveSpeed"),
                makeConfigRow("冲刺倍率", P, "SprintMultiplier"),
                makeConfigRow("鼠标灵敏度", P, "MouseSensitivity"),
                makeConfigRow("视点高度", P, "EyeHeight"),
                makeConfigRow("交互距离", P, "InteractDistance"),
                makeConfigRow("重力", P, "Gravity"),
                makeConfigRow("跳跃速度", P, "JumpSpeed"),
                makeConfigRow("质量", P, "Mass"),
                makeConfigRow("线性阻尼", P, "LinearDamping"),

            }),
            makeCollapsible("战斗配置", {
                makeConfigRow("玩家最大HP", C, "PlayerMaxHP"),
                makeConfigRow("玩家攻击力", C, "PlayerAttackDamage"),
                makeConfigRow("攻击距离", C, "PlayerAttackRange"),
                makeConfigRow("攻击冷却", C, "PlayerAttackCooldown"),
                makeConfigRow("无敌时间", C, "InvincibilityTime"),
            }),
            makeCollapsible("击退参数", {
                makeConfigRow("持续秒数", KN, "Duration"),
                makeConfigRow("衰减率", KN, "DecayRate"),
                makeConfigRow("Boss抗性", KN, "BossResistance"),
                makeConfigRow("最小速度", KN, "MinVelocity"),
            }),
        },
    }

    return UI.Panel {
        children = {
            sectionTitle("玩家 & 战斗"),
            UI.Panel {
                flexDirection = "row",
                children = { leftCol, rightCol },
            },
        },
    }
end

-- ── 敌人配置区 ──
local function buildEnemyConfig()
    local ENEMY_FIELDS = {
        "HP", "Damage", "AttackRange", "DetectRange", "ChaseSpeed", "PatrolSpeed",
        "AttackCooldown", "MoveSpeed", "ProjectileSpeed", "RetreatRange", "Scale",
        "AOERange", "AOECooldown", "SlowMult", "SlowDuration", "BurnDPS", "BurnDuration",
        "FlySpeed", "DiveSpeed", "FlyHeight", "CircleRadius", "DiveCooldown",
        "BreathCooldown", "BreathDamage", "BreathSpeed",
        "Phase2Threshold", "Phase3Threshold",
        "StompCooldown", "StompRange", "StompDamage",
        "RainCooldown", "RainCount", "RainDamage", "RainSpeed",
        "TeleportCooldown", "LaserCooldown", "LaserDamage", "LaserDuration",
        "SummonCooldown", "SummonCount",
    }

    local function makeEnemySec(title, cfg)
        local rows = {}
        for _, f in ipairs(ENEMY_FIELDS) do
            if cfg[f] ~= nil and type(cfg[f]) == "number" then
                table.insert(rows, makeConfigRow(f, cfg, f))
            end
        end
        return makeCollapsible(title, rows)
    end

    local E = GameConfig.Enemies

    -- 分两列
    local leftCol = UI.Panel {
        flex = 1, marginRight = 4,
        children = {
            makeEnemySec("近战怪 (暗影兽)", E.Melee),
            makeEnemySec("远程怪 (邪灵)", E.Ranged),
            makeEnemySec("定时Boss", E.Boss),
            makeEnemySec("精英近战", E.EliteMelee),
            makeEnemySec("精英远程", E.EliteRanged),
        },
    }

    local rightCol = UI.Panel {
        flex = 1, marginLeft = 4,
        children = {
            makeEnemySec("精英AOE (炼狱术士)", E.EliteAOE),
            makeEnemySec("精英Debuff (瘟疫幽魂)", E.EliteDebuff),
            makeEnemySec("龙Boss", E.DragonBoss),
            makeEnemySec("终极Boss", E.UltimateBoss),
        },
    }

    -- 等级缩放 + 波次
    local LS = E.LevelScaling
    local W = E.Wave
    local bottomRow = UI.Panel {
        flexDirection = "row", marginTop = 4,
        children = {
            UI.Panel {
                flex = 1, marginRight = 4,
                children = {
                    makeCollapsible("等级缩放", {
                        makeConfigRow("HP倍率/级", LS, "HPMult"),
                        makeConfigRow("伤害倍率/级", LS, "DamageMult"),
                        makeConfigRow("速度倍率/级", LS, "SpeedMult"),
                        makeConfigRow("精英解锁等级", LS, "EliteUnlockLevel"),
                        makeConfigRow("精英概率", LS, "EliteChance"),
                        makeConfigRow("Boss体型/级", LS, "LevelBossScale"),
                    }),
                },
            },
            UI.Panel {
                flex = 1, marginLeft = 4,
                children = {
                    makeCollapsible("波次刷怪", {
                        makeConfigRow("小波间隔(s)", W, "SmallInterval"),
                        makeConfigRow("大波间隔(s)", W, "BigInterval"),
                        makeConfigRow("升级间隔(s)", W, "MonsterUpgrade"),
                        makeConfigRow("Boss间隔(s)", W, "BossInterval"),
                        makeConfigRow("小波数量", W, "SmallCount"),
                        makeConfigRow("大波数量", W, "BigCount"),
                        makeConfigRow("每级+数量", W, "CountGrowth"),
                        makeConfigRow("单波上限", W, "CountMax"),
                        makeConfigRow("AOE解锁(s)", W, "EliteAOEUnlockTime"),
                        makeConfigRow("Debuff解锁(s)", W, "EliteDebuffUnlockTime"),
                        makeConfigRow("XP倍率/级", W, "XPPerLevelMult"),
                        makeConfigRow("Boss奖励倍率", W, "BossRewardMult"),
                    }),
                },
            },
        },
    }

    -- 区域Boss
    local AREA_BOSS_FIELDS = { "hp", "damage", "attackRange", "detectRange", "chaseSpeed", "attackCooldown" }
    local abSections = {}
    for _, abId in ipairs(GameConfig.AreaBossOrder) do
        local ab = GameConfig.AreaBosses[abId]
        if ab then
            local rows = {
                UI.Label {
                    text = string.format("(%d,%d) → %s", ab.spawnPos.x, ab.spawnPos.z, ab.dropEquip or "?"),
                    fontSize = 9, fontColor = DIM_COLOR, marginBottom = 3,
                },
            }
            for _, f in ipairs(AREA_BOSS_FIELDS) do
                if ab[f] ~= nil then table.insert(rows, makeConfigRow(f, ab, f)) end
            end
            table.insert(abSections, makeCollapsible(string.format("%s %s", ab.icon, ab.name), rows))
        end
    end

    return UI.Panel {
        children = {
            sectionTitle("敌人配置"),
            UI.Panel { flexDirection = "row", children = { leftCol, rightCol } },
            bottomRow,
            makeCollapsible("区域Boss (" .. #GameConfig.AreaBossOrder .. ")", abSections),
        },
    }
end

-- ── 武器 & 技能配置区 ──
local function buildWeaponConfig()
    local WEAPON_FIELDS = {
        "damage", "range", "dotMin", "cooldown", "knockbackForce",
        "splashDamage", "splashRange", "speed", "duration",
        "chainRange", "maxChains", "tickDamage", "tickInterval",
        "freezeDuration", "triggerRange", "maxTraps",
        "healAmount", "atkSpdBonus", "moveSpdBonus",
        "orbCount", "orbRadius", "orbSpeed",
        "maxClones", "cloneSpeed", "cloneRange", "slowPct",
    }

    local weaponSections = {}
    for _, wId in ipairs(GameConfig.Weapons.Order) do
        local w = GameConfig.Weapons[wId]
        if w then
            local rows = {}
            for _, f in ipairs(WEAPON_FIELDS) do
                if w[f] ~= nil and type(w[f]) == "number" then
                    table.insert(rows, makeConfigRow(f, w, f))
                end
            end
            if #rows > 0 then
                table.insert(weaponSections, makeCollapsible(
                    string.format("%s %s (%s)", w.icon or "", w.name or wId, w.skill or ""), rows))
            end
        end
    end

    local SKILL_FIELDS = { "damage", "range", "duration", "cooldown", "strikes", "ticks", "pullStrength", "healPercent", "shieldDuration" }
    local skillSections = {}
    for _, sk in ipairs(GameConfig.LevelSkills) do
        local rows = {
            UI.Label {
                text = string.format("[%s] %s", sk.type or "", sk.desc or ""),
                fontSize = 9, fontColor = DIM_COLOR, marginBottom = 3,
            },
        }
        for _, f in ipairs(SKILL_FIELDS) do
            if sk[f] ~= nil and type(sk[f]) == "number" then
                table.insert(rows, makeConfigRow(f, sk, f))
            end
        end
        table.insert(skillSections, makeCollapsible(
            string.format("%s %s", sk.icon or "", sk.name or sk.id), rows))
    end

    local KB = GameConfig.KillBonus

    -- 分两列
    local leftCol = UI.Panel {
        flex = 1, marginRight = 4,
        children = {
            makeCollapsible("武器 (" .. #GameConfig.Weapons.Order .. "件)", weaponSections),
        },
    }
    local rightCol = UI.Panel {
        flex = 1, marginLeft = 4,
        children = {
            makeCollapsible("十级技能 (" .. #GameConfig.LevelSkills .. "个)", skillSections),
            makeCollapsible("击杀加成", {
                makeConfigRow("层级间隔", KB, "TierInterval"),
                makeConfigRow("每层加成", KB, "BonusPerTier"),
                makeConfigRow("最大冷却减免", KB, "MaxCooldownReduction"),
                makeConfigRow("被动解锁间隔", KB, "PassiveInterval"),
            }),
        },
    }

    return UI.Panel {
        children = {
            sectionTitle("武器 & 技能"),
            UI.Panel { flexDirection = "row", children = { leftCol, rightCol } },
        },
    }
end

-- ── 装备 & 升级配置区 ──
local function buildEquipConfig()
    local equipSections = {}
    for _, eqId in ipairs(GameConfig.EquipmentOrder) do
        local eq = GameConfig.Equipment[eqId]
        if eq then
            local rows = {
                UI.Label { text = eq.desc or "", fontSize = 9, fontColor = DIM_COLOR, marginBottom = 3 },
            }
            if eq.passive then
                for k, v in pairs(eq.passive) do
                    if type(v) == "number" then table.insert(rows, makeConfigRow("被动:" .. k, eq.passive, k)) end
                end
            end
            if eq.proc then
                for k, v in pairs(eq.proc) do
                    if type(v) == "number" then table.insert(rows, makeConfigRow("触发:" .. k, eq.proc, k)) end
                end
            end
            table.insert(equipSections, makeCollapsible(
                string.format("%s %s", eq.icon or "", eq.name or eqId), rows))
        end
    end

    local LV = GameConfig.Leveling

    local leftCol = UI.Panel {
        flex = 1, marginRight = 4,
        children = {
            makeCollapsible("装备 (" .. #GameConfig.EquipmentOrder .. "件)", equipSections),
        },
    }
    local rightCol = UI.Panel {
        flex = 1, marginLeft = 4,
        children = {
            makeCollapsible("升级系统", {
                makeConfigRow("每球经验", LV, "XPPerOrb"),
                makeConfigRow("普怪掉球数", LV, "OrbsNormal"),
                makeConfigRow("Boss掉球数", LV, "OrbsBoss"),
                makeConfigRow("初始升级经验", LV, "BaseXP"),
                makeConfigRow("经验递增倍率", LV, "GrowthRate"),
                makeConfigRow("经验球速度", LV, "OrbSpeed"),
                makeConfigRow("吸收距离", LV, "OrbCollectDist"),
                makeConfigRow("磁吸距离", LV, "OrbMagnetDist"),
                makeConfigRow("拾取加成间隔(击杀)", LV, "OrbRangeKillInterval"),
                makeConfigRow("拾取加成幅度(%)", LV, "OrbRangeBonusPct"),
                makeConfigRow("血包掉率", LV, "HealthDropChance"),
                makeConfigRow("血包回复", LV, "HealthDropHeal"),
                makeConfigRow("血包存在时间", LV, "HealthDropLife"),
                makeConfigRow("拾取距离", LV, "HealthCollectDist"),
            }),
            -- 属性选项（只读）
            makeCollapsible("属性选项 (只读)", (function()
                local attrRows = {}
                for _, attr in ipairs(GameConfig.Attributes) do
                    table.insert(attrRows, UI.Label {
                        text = string.format("%s %s: %s", attr.icon, attr.name, attr.desc),
                        fontSize = 9, fontColor = DIM_COLOR, marginBottom = 2,
                    })
                end
                return attrRows
            end)()),
        },
    }

    return UI.Panel {
        children = {
            sectionTitle("装备 & 升级"),
            UI.Panel { flexDirection = "row", children = { leftCol, rightCol } },
        },
    }
end

-- ── 重启区 ──
local function buildRestartSection()
    local RESTART_BG    = { 180, 80, 30, 255 }
    local RESTART_HOVER = { 220, 100, 40, 255 }
    local SAVE_BG       = { 30, 120, 180, 255 }
    local SAVE_HOVER    = { 40, 150, 220, 255 }
    local CLEAR_BG      = { 100, 50, 50, 255 }
    local CLEAR_HOVER   = { 140, 65, 65, 255 }

    return UI.Panel {
        children = {
            sectionTitle("保存 & 重启"),
            UI.Label {
                text = "保存修改的数值为默认值并重新开始游戏",
                fontSize = 11, fontColor = DIM_COLOR, marginBottom = 8,
            },
            UI.Panel {
                flexDirection = "row", gap = 8, marginBottom = 12,
                children = {
                    UI.Button {
                        text = "保存并重新开始",
                        fontSize = 14, fontWeight = "bold",
                        backgroundColor = RESTART_BG,
                        hoverBackgroundColor = RESTART_HOVER,
                        textColor = { 255, 255, 255, 255 },
                        borderRadius = 6,
                        paddingHorizontal = 16, paddingVertical = 10,
                        flex = 1,
                        onClick = function(self)
                            print("[EditorDevTab] === 保存并重新开始 ===")
                            -- 1. flush 所有未提交的输入框修改
                            flushPendingInputs()
                            -- 2. 保存到 config-overrides.json
                            local ok, count = saveConfigOverrides()
                            print("[EditorDevTab] saveConfigOverrides => ok=" .. tostring(ok) .. " count=" .. tostring(count))
                            if ok then
                                UI.Toast.Show("已保存 " .. count .. " 项配置，正在重启...", { variant = "success", duration = 1.5 })
                            else
                                UI.Toast.Show("没有需要保存的修改", { variant = "warning", duration = 1.5 })
                            end
                            -- 3. 重启游戏（无论是否有修改都重启）
                            if DevRestartGame then
                                DevRestartGame()
                            else
                                UI.Toast.Show("重启函数未注册", { variant = "error", duration = 2 })
                            end
                        end,
                    },
                    UI.Button {
                        text = "清除覆盖",
                        fontSize = 13,
                        backgroundColor = CLEAR_BG,
                        hoverBackgroundColor = CLEAR_HOVER,
                        textColor = { 255, 255, 255, 255 },
                        borderRadius = 6,
                        paddingHorizontal = 14, paddingVertical = 8,
                        onClick = function(self)
                            if fileSystem:FileExists(OVERRIDES_FILE) then
                                fileSystem:Delete(OVERRIDES_FILE)
                                UI.Toast.Show("已清除配置覆盖，下次启动使用代码默认值", { variant = "info", duration = 2 })
                            else
                                UI.Toast.Show("没有覆盖文件需要清除", { variant = "warning", duration = 1.5 })
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ============================================================================
-- 主入口：CreateDevPanel — 单页全屏滚动
-- ============================================================================

function EditorDevTab.CreateDevPanel()
    -- 重建面板时清空注册表，避免旧输入框引用残留
    pendingInputs_ = {}
    changeLog_ = {}

    local statusSection = buildStatusSection()
    local quickSection  = buildQuickActions()
    local safeZoneSection = buildSafeZoneConfig()
    local playerSection = buildPlayerConfig()
    local enemySection  = buildEnemyConfig()
    local weaponSection = buildWeaponConfig()
    local equipSection  = buildEquipConfig()
    local restartSection = buildRestartSection()

    return UI.Panel {
        flexGrow = 1, flexBasis = 0,
        children = {
            UI.ScrollView {
                flexGrow = 1, flexBasis = 0,
                padding = 12,
                children = {
                    statusSection,
                    quickSection,
                    safeZoneSection,
                    playerSection,
                    enemySection,
                    weaponSection,
                    equipSection,
                    restartSection,
                },
            },
        },
    }
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 在屏幕上用 Toast 显示修改摘要
---@param duration number 显示持续秒数
function EditorDevTab.ShowChangeSummary(duration)
    local changes = changeLog_
    if #changes == 0 then return end

    duration = duration or 2

    -- 构建摘要文本
    local lines = { "已修改 " .. #changes .. " 项配置:" }
    for _, c in ipairs(changes) do
        table.insert(lines, "  " .. c.label .. ": " .. tostring(c.oldVal) .. " → " .. tostring(c.newVal))
    end
    local msg = table.concat(lines, "\n")

    UI.Toast.Show(msg, { variant = "success", duration = duration })
end

function EditorDevTab.Init(scene, controller)
    scene_ = scene
    fpController_ = controller
end

function EditorDevTab.Refresh()
    refreshStatus()
end

function EditorDevTab.Update(dt)
    if godMode_ and not PlayerHealth.IsDead() then
        if PlayerHealth.GetHP() < PlayerHealth.GetMaxHP() then
            PlayerHealth.Heal(PlayerHealth.GetMaxHP())
        end
    end
end

--- 兼容接口（Toast 自带计时，无需手动更新）
function EditorDevTab.UpdateSummary(dt)
end

function EditorDevTab.IsGodMode()
    return godMode_
end

function EditorDevTab.GetSpeedMult()
    return speedMult_
end

return EditorDevTab
