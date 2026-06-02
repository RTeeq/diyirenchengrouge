-- ============================================================================
-- StartScreen.lua — 游戏开始界面 + 存档选择
-- 封面图背景 + 沉浸式 UI 设计，支持 4 存档槽位
-- ============================================================================

local GameConfig = require("config.GameConfig")
local SettingsUI = require("ui.SettingsUI")
local SaveSystem = require("core.SaveSystem")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local StartScreen = {}

local root_ = nil
local onStart_ = nil
local onExitGame_ = nil
local onLoadSlot_ = nil   -- 读取存档回调: cb(slot)
local onNewSlot_ = nil    -- 新建存档回调: cb(slot)

-- 动画状态
local titleLabel_ = nil
local glowTimer_ = 0

-- 存档面板
local savePanel_ = nil
local slotCards_ = {}    -- { [1..4] = cardPanel }



-- ============================================================================
-- 内部：格式化时间戳
-- ============================================================================
local function formatTime(ts)
    if not ts or ts == 0 then return "" end
    local ok, str = pcall(os.date, "%m/%d %H:%M", ts)
    if ok then return str end
    return ""
end

-- ============================================================================
-- 内部：创建单个槽位卡片
-- ============================================================================
local function createSlotCard(slot, info)
    local hasData = info ~= nil
    local cardChildren = {}

    if hasData then
        -- 有存档：显示信息
        local gold = info.gold or 0
        local crystal = info.crystal or 0
        local timeStr = formatTime(info.timestamp)

        table.insert(cardChildren, UI.Label {
            text = "存档 " .. slot,
            fontSize = 16,
            fontWeight = "bold",
            fontColor = { 255, 245, 255, 240 },
            marginBottom = 8,
        })
        table.insert(cardChildren, UI.Label {
            text = "💰 " .. gold .. "   💎 " .. crystal,
            fontSize = 13,
            fontColor = { 255, 220, 100, 220 },
            marginBottom = 4,
        })
        if timeStr ~= "" then
            table.insert(cardChildren, UI.Label {
                text = timeStr,
                fontSize = 11,
                fontColor = { 180, 180, 200, 160 },
                marginBottom = 10,
            })
        end
        -- 继续游戏按钮
        table.insert(cardChildren, UI.Panel {
            flexDirection = "row",
            children = {
                UI.Button {
                    text = "继续",
                    fontSize = 13,
                    width = 70,
                    height = 32,
                    variant = "primary",
                    borderRadius = 16,
                    marginRight = 8,
                    onClick = function()
                        if onLoadSlot_ then onLoadSlot_(slot) end
                    end,
                },
                UI.Button {
                    text = "删除",
                    fontSize = 13,
                    width = 70,
                    height = 32,
                    variant = "outline",
                    borderRadius = 16,
                    onClick = function()
                        SaveSystem.Delete(slot)
                        refreshSlots()
                    end,
                },
            },
        })
    else
        -- 空槽位
        table.insert(cardChildren, UI.Label {
            text = "存档 " .. slot,
            fontSize = 16,
            fontWeight = "bold",
            fontColor = { 200, 200, 220, 180 },
            marginBottom = 8,
        })
        table.insert(cardChildren, UI.Label {
            text = "- 空 -",
            fontSize = 13,
            fontColor = { 140, 140, 160, 120 },
            marginBottom = 14,
        })
        table.insert(cardChildren, UI.Button {
            text = "新建",
            fontSize = 13,
            width = 70,
            height = 32,
            variant = "primary",
            borderRadius = 16,
            onClick = function()
                if onNewSlot_ then onNewSlot_(slot) end
            end,
        })
    end

    return UI.Panel {
        id = "slotCard" .. slot,
        width = 170,
        padding = { 14, 16 },
        marginRight = 12,
        backgroundColor = hasData and { 30, 25, 50, 200 } or { 20, 20, 30, 150 },
        borderRadius = 12,
        borderWidth = 1,
        borderColor = hasData and { 120, 80, 200, 120 } or { 60, 60, 80, 80 },
        alignItems = "center",
        children = cardChildren,
    }
end

-- ============================================================================
-- 刷新所有槽位卡片
-- ============================================================================
function refreshSlots()
    if not savePanel_ then return end
    UIHelper.DestroyChildren(savePanel_)

    -- 标题
    savePanel_:AddChild(UI.Label {
        text = "选择存档",
        fontSize = 28,
        fontWeight = "bold",
        fontColor = { 220, 200, 255, 240 },
        marginBottom = 24,
    })

    -- 横排容器放存档卡片
    local rowContainer = UI.Panel {
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "flex-start",
        flexWrap = "wrap",
    }

    local infos = SaveSystem.GetAllSlotInfos()
    for i = 1, SaveSystem.GetMaxSlots() do
        local card = createSlotCard(i, infos[i])
        rowContainer:AddChild(card)
        slotCards_[i] = card
    end
    savePanel_:AddChild(rowContainer)

    -- 返回按钮
    savePanel_:AddChild(UI.Panel {
        width = "100%",
        alignItems = "center",
        marginTop = 16,
        children = {
            UI.Button {
                text = "返  回",
                fontSize = 18,
                width = 200,
                height = 48,
                variant = "outline",
                borderRadius = 24,
                onClick = function()
                    hideSavePanel()
                end,
            },
        },
    })
end

-- ============================================================================
-- 存档面板显示/隐藏
-- ============================================================================
local mainContent_ = nil

local function showSavePanel()
    if mainContent_ then mainContent_:Hide() end
    if savePanel_ then
        refreshSlots()
        savePanel_:Show()
    end
end

function hideSavePanel()
    if savePanel_ then savePanel_:Hide() end
    if mainContent_ then mainContent_:Show() end
end

-- ============================================================================
-- 初始化
-- ============================================================================

---@return table UI 面板
function StartScreen.Init()
    local gameName = GameConfig.Title
    if not gameName or gameName == "" then
        gameName = "暗影之村"
    end

    -- 主内容区（标题+按钮）
    mainContent_ = UI.Panel {
        id = "mainContent",
        position = "absolute",
        left = 0, right = 0, bottom = 0,
        height = "100%",
        justifyContent = "flex-end",
        paddingBottom = 80,
        paddingLeft = 60,
        children = {
            -- 游戏标题
            UI.Label {
                id = "startTitle",
                text = gameName,
                fontSize = 64,
                fontWeight = "bold",
                fontColor = { 255, 245, 255, 255 },
                marginBottom = 6,
            },
            -- 装饰分隔线
            UI.Panel {
                width = 260,
                height = 3,
                backgroundColor = { 180, 130, 255, 120 },
                borderRadius = 2,
                marginTop = 8,
                marginBottom = 20,
            },
            -- 版本号
            UI.Label {
                id = "startSubtitle",
                text = "Ver " .. GameConfig.Version,
                fontSize = 16,
                fontColor = { 160, 150, 200, 120 },
                marginBottom = 40,
            },
            -- 创建新游戏
            UI.Button {
                text = "创 建 新 游 戏",
                fontSize = 24,
                fontWeight = "bold",
                fontColor = { 255, 255, 255, 240 },
                width = 300,
                height = 64,
                variant = "primary",
                borderRadius = 32,
                marginBottom = 16,
                onClick = function(self)
                    -- 自动找第一个空槽位创建新游戏
                    local infos = SaveSystem.GetAllSlotInfos()
                    local emptySlot = nil
                    for i = 1, SaveSystem.GetMaxSlots() do
                        if not infos[i] then
                            emptySlot = i
                            break
                        end
                    end
                    if emptySlot then
                        if onNewSlot_ then onNewSlot_(emptySlot) end
                    else
                        -- 所有槽位已满，提示并跳转存档管理
                        UI.Toast.Show("存档已满，请先删除旧存档", { variant = "warning", duration = 2 })
                        showSavePanel()
                    end
                end,
            },
            -- 游戏存档
            UI.Button {
                text = "游 戏 存 档",
                fontSize = 24,
                fontWeight = "bold",
                fontColor = { 255, 255, 255, 240 },
                width = 300,
                height = 64,
                variant = "outline",
                borderRadius = 32,
                marginBottom = 16,
                onClick = function(self)
                    showSavePanel()
                end,
            },
            -- 游戏设置
            UI.Button {
                text = "游 戏 设 置",
                fontSize = 24,
                fontWeight = "bold",
                fontColor = { 255, 255, 255, 240 },
                width = 300,
                height = 64,
                variant = "outline",
                borderRadius = 32,
                marginBottom = 16,
                onClick = function(self)
                    SettingsUI.Show()
                end,
            },
            -- 退出游戏
            UI.Button {
                text = "退 出 游 戏",
                fontSize = 24,
                fontWeight = "bold",
                fontColor = { 200, 180, 220, 200 },
                width = 300,
                height = 64,
                variant = "ghost",
                borderRadius = 32,
                marginBottom = 16,
                onClick = function(self)
                    if onExitGame_ then onExitGame_() end
                end,
            },
        },
    }

    -- 存档选择面板（初始隐藏）
    savePanel_ = UI.Panel {
        id = "savePanel",
        position = "absolute",
        left = 0, right = 0, top = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 160 },
        visible = false,
    }

    root_ = UI.Panel {
        id = "startScreen",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        visible = true,
        children = {
            -- 层1：封面图背景
            UI.Panel {
                position = "absolute",
                top = 0, left = 0, right = 0, bottom = 0,
                backgroundImage = "image/游戏封面_20260423223012.png",
                backgroundFit = "cover",
                pointerEvents = "none",
            },
            -- 层2：整体暗化遮罩
            UI.Panel {
                position = "absolute",
                top = 0, left = 0, right = 0, bottom = 0,
                backgroundColor = { 0, 0, 0, 120 },
                pointerEvents = "none",
            },
            -- 层3：顶部光晕装饰
            UI.Panel {
                position = "absolute",
                top = 0, left = 0, right = 0,
                height = 3,
                backgroundColor = { 180, 120, 255, 80 },
                pointerEvents = "none",
            },
            -- 主内容
            mainContent_,
            -- 存档面板
            savePanel_,
        },
    }

    titleLabel_ = root_:FindById("startTitle")

    print("[StartScreen] 初始化完成（含存档系统）")
    return root_
end

-- ============================================================================
-- 更新（标题呼吸动画）
-- ============================================================================

---@param dt number
function StartScreen.Update(dt)
    if not root_ or not titleLabel_ then return end
    glowTimer_ = glowTimer_ + dt

    local titleAlpha = math.floor(220 + 35 * math.sin(glowTimer_ * 1.2))
    titleLabel_:SetStyle({ fontColor = { 255, 245, 255, titleAlpha } })
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

function StartScreen.Show()
    if root_ then root_:Show() end
    hideSavePanel()
end

function StartScreen.Hide()
    if root_ then root_:Hide() end
end

---@param cb function 原始开始回调（不再直接使用）
function StartScreen.OnStart(cb)
    onStart_ = cb
end

---@param cb function(slot) 读取存档回调
function StartScreen.OnLoadSlot(cb)
    onLoadSlot_ = cb
end

---@param cb function(slot) 新建存档回调
function StartScreen.OnNewSlot(cb)
    onNewSlot_ = cb
end

---@param cb function
function StartScreen.OnExitGame(cb)
    onExitGame_ = cb
end

return StartScreen
