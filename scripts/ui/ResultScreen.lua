-- ============================================================================
-- ResultScreen.lua — 死亡 + 结算统一界面
-- 合并了原死亡界面和结算界面：
--   标题"你已死亡" + 评价 + 统计数据 + 广告复活/重新来过按钮
-- ============================================================================

local GameConfig = require("config.GameConfig")
local LevelSystem = require("combat.LevelSystem")
local EnemyManager = require("combat.EnemyManager")
local GameManager = require("core.GameManager")
local HUD = require("ui.HUD")
local UI = require("urhox-libs/UI")

local ResultScreen = {}

local root_ = nil
local onRestart_ = nil
local onAdRevive_ = nil

-- 数据标签引用
local timeValue_ = nil
local killValue_ = nil
local levelValue_ = nil
local itemValue_ = nil
local ratingLabel_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

---@return table UI 面板
function ResultScreen.Init()
    root_ = UI.Panel {
        id = "resultScreen",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 10, 0, 0, 210 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                alignItems = "center",
                width = 320,
                padding = { 30, 30 },
                backgroundColor = { 20, 10, 25, 240 },
                borderRadius = 16,
                borderWidth = 1,
                borderColor = { 160, 50, 50, 120 },
                children = {
                    -- 猫咪图片
                    UI.Panel {
                        backgroundImage = "image/result_cat.png",
                        backgroundFit = "cover",
                        width = 120,
                        height = 120,
                        borderRadius = 60,
                        marginBottom = 12,
                    },

                    -- 死亡标题
                    UI.Label {
                        text = "你已死亡",
                        fontSize = 34,
                        fontWeight = "bold",
                        fontColor = { 200, 40, 40, 255 },
                        marginBottom = 6,
                    },

                    -- 副标题
                    UI.Label {
                        text = "被黑暗力量吞噬...",
                        fontSize = 13,
                        fontColor = { 180, 150, 150, 180 },
                        marginBottom = 12,
                    },

                    -- 评价
                    UI.Label {
                        id = "ratingLabel",
                        text = "",
                        fontSize = 14,
                        fontColor = { 255, 220, 100, 200 },
                        marginBottom = 20,
                    },

                    -- 分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = { 160, 60, 60, 60 },
                        marginBottom = 16,
                    },

                    -- 统计行：存活时间
                    createStatRow("statTime", "⏱ 存活时间", "00:00"),
                    -- 统计行：击杀数
                    createStatRow("statKills", "💀 击杀数", "0"),
                    -- 统计行：达到等级
                    createStatRow("statLevel", "⭐ 达到等级", "Lv.1"),
                    -- 统计行：收集物品
                    createStatRow("statItems", "🎒 收集物品", "0/10"),

                    -- 分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = { 160, 60, 60, 60 },
                        marginTop = 4,
                        marginBottom = 20,
                    },

                    -- 广告复活按钮
                    UI.Button {
                        id = "adReviveBtn",
                        text = "📺 观看广告复活",
                        fontSize = 16,
                        width = 220,
                        height = 46,
                        variant = "primary",
                        borderRadius = 10,
                        marginBottom = 12,
                        onClick = function(self)
                            if onAdRevive_ then onAdRevive_() end
                        end,
                    },

                    -- 重新来过按钮
                    UI.Button {
                        text = "重新来过",
                        fontSize = 15,
                        width = 200,
                        height = 44,
                        borderRadius = 10,
                        onClick = function(self)
                            if onRestart_ then onRestart_() end
                        end,
                    },
                },
            },
        },
    }

    timeValue_   = root_:FindById("statTime_val")
    killValue_   = root_:FindById("statKills_val")
    levelValue_  = root_:FindById("statLevel_val")
    itemValue_   = root_:FindById("statItems_val")
    ratingLabel_ = root_:FindById("ratingLabel")

    print("[ResultScreen] 初始化完成（统一死亡+结算界面）")
    return root_
end

--- 创建一行统计数据
---@param id string
---@param label string
---@param defaultVal string
---@return table
function createStatRow(id, label, defaultVal)
    return UI.Panel {
        flexDirection = "row",
        justifyContent = "space-between",
        width = "100%",
        paddingLeft = 10,
        paddingRight = 10,
        marginBottom = 12,
        children = {
            UI.Label {
                text = label,
                fontSize = 15,
                fontColor = { 180, 170, 210, 200 },
            },
            UI.Label {
                id = id .. "_val",
                text = defaultVal,
                fontSize = 15,
                fontWeight = "bold",
                fontColor = { 255, 255, 255, 240 },
            },
        },
    }
end

-- ============================================================================
-- 显示结算（刷新数据后展示）
-- ============================================================================

function ResultScreen.Show()
    if not root_ then return end

    -- 收集统计数据
    local gameTime = HUD.GetGameTime()
    local kills = EnemyManager.GetKillCount()
    local level = LevelSystem.GetLevel()
    local items = GameManager.GetItemCount()

    -- 格式化时间
    local m = math.floor(gameTime / 60)
    local s = math.floor(gameTime % 60)
    local timeStr = string.format("%02d:%02d", m, s)

    -- 更新 UI
    if timeValue_ then timeValue_:SetText(timeStr) end
    if killValue_ then killValue_:SetText(tostring(kills)) end
    if levelValue_ then levelValue_:SetText("Lv." .. level) end
    if itemValue_ then itemValue_:SetText(items .. "/10") end

    -- 评价系统
    local rating = getRating(gameTime, kills, level)
    if ratingLabel_ then ratingLabel_:SetText(rating) end

    root_:Show()

    -- 确保显示鼠标光标（按钮可点击）
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true
end

function ResultScreen.Hide()
    if root_ then root_:Hide() end
end

--- 根据数据生成评价
---@param time number
---@param kills number
---@param level number
---@return string
function getRating(time, kills, level)
    local score = math.floor(time / 60) * 10 + kills + level * 20
    if score >= 300 then
        return "评价：S — 暗影猎手"
    elseif score >= 200 then
        return "评价：A — 驱魔高手"
    elseif score >= 120 then
        return "评价：B — 合格冒险者"
    elseif score >= 60 then
        return "评价：C — 初出茅庐"
    else
        return "评价：D — 再接再厉"
    end
end

-- ============================================================================
-- 回调
-- ============================================================================

---@param cb function
function ResultScreen.OnRestart(cb)
    onRestart_ = cb
end

---@param cb function
function ResultScreen.OnAdRevive(cb)
    onAdRevive_ = cb
end

return ResultScreen
