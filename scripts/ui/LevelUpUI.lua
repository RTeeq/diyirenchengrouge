-- ============================================================================
-- LevelUpUI.lua — 升级选择界面
-- 属性三选一 / 技能三选一（每10级）
-- ============================================================================

local GameConfig = require("config.GameConfig")
local LevelSystem = require("combat.LevelSystem")
local GameManager = require("core.GameManager")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local LevelUpUI = {}

local root_ = nil
local titleLabel_ = nil
local subtitleLabel_ = nil
local cardsContainer_ = nil
local refreshContainer_ = nil  -- 刷新按钮容器
local onSelectionDone_ = nil  -- 选完后回调（恢复游戏）

-- 技能刷新机制
local FREE_REFRESHES = 3
local REFRESH_COST = 100
local refreshCount_ = 0  -- 当前已用刷新次数

-- ============================================================================
-- 初始化
-- ============================================================================

---@return table 面板节点
function LevelUpUI.Init()
    root_ = UI.Panel {
        id = "levelUpOverlay",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 0, 0, 0, 180 },
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                alignItems = "center",
                width = "90%",
                maxWidth = 600,
                children = {
                    -- 标题
                    UI.Label {
                        id = "lvlTitle",
                        text = "升级！",
                        fontSize = 32,
                        fontWeight = "bold",
                        fontColor = { 255, 220, 80, 255 },
                        marginBottom = 6,
                    },
                    UI.Label {
                        id = "lvlSubtitle",
                        text = "选择一项属性加成",
                        fontSize = 14,
                        fontColor = { 200, 200, 200, 200 },
                        marginBottom = 24,
                    },
                    -- 选项卡片容器
                    UI.Panel {
                        id = "lvlCards",
                        flexDirection = "row",
                        justifyContent = "center",
                        alignItems = "stretch",
                        width = "100%",
                        flexWrap = "wrap",
                    },
                    -- 刷新按钮容器
                    UI.Panel {
                        id = "lvlRefresh",
                        flexDirection = "row",
                        justifyContent = "center",
                        alignItems = "center",
                        width = "100%",
                        marginTop = 16,
                    },
                },
            },
        },
    }

    titleLabel_ = root_:FindById("lvlTitle")
    subtitleLabel_ = root_:FindById("lvlSubtitle")
    cardsContainer_ = root_:FindById("lvlCards")
    refreshContainer_ = root_:FindById("lvlRefresh")

    print("[LevelUpUI] 初始化完成")
    return root_
end

-- ============================================================================
-- 构建选项卡片
-- ============================================================================

--- 创建属性选择卡片
local function buildAttributeCards()
    UIHelper.DestroyChildren(cardsContainer_)
    if refreshContainer_ then UIHelper.DestroyChildren(refreshContainer_) end

    local choices = LevelSystem.GetAttributeChoices()
    local cardColors = {
        { 60, 40, 90 },    -- 紫
        { 30, 60, 80 },    -- 蓝
        { 70, 50, 20 },    -- 金
    }

    for i, attr in ipairs(choices) do
        local bg = cardColors[i] or cardColors[1]
        local card = UI.Panel {
            width = 170,
            margin = 8,
            padding = 16,
            backgroundColor = { bg[1], bg[2], bg[3], 220 },
            borderRadius = 12,
            borderWidth = 2,
            borderColor = { 200, 180, 100, 100 },
            alignItems = "center",
            children = {
                -- 图标
                UI.Label {
                    text = attr.icon,
                    fontSize = 36,
                    marginBottom = 10,
                },
                -- 名称
                UI.Label {
                    text = attr.name,
                    fontSize = 16,
                    fontWeight = "bold",
                    fontColor = { 255, 240, 200, 255 },
                    marginBottom = 6,
                },
                -- 描述
                UI.Label {
                    text = attr.desc,
                    fontSize = 11,
                    fontColor = { 200, 200, 200, 200 },
                    textAlign = "center",
                    marginBottom = 14,
                },
                -- 选择按钮
                UI.Button {
                    text = "选择",
                    fontSize = 13,
                    width = 100,
                    height = 34,
                    variant = "primary",
                    borderRadius = 6,
                    onClick = function(self)
                        LevelSystem.ApplyAttribute(attr)
                        LevelUpUI.OnChoiceMade()
                    end,
                },
            },
        }
        cardsContainer_:AddChild(card)
    end
end

-- 前置声明（buildRefreshButton 和 buildSkillCards 互相引用）
local buildSkillCards
local buildRefreshButton

--- 构建刷新按钮
buildRefreshButton = function()
    if not refreshContainer_ then return end
    UIHelper.DestroyChildren(refreshContainer_)

    local isFree = refreshCount_ < FREE_REFRESHES
    local remaining = FREE_REFRESHES - refreshCount_
    local gold = GameManager.GetGold()
    local canAfford = isFree or gold >= REFRESH_COST

    local btnText
    if isFree then
        btnText = "🔄 刷新（免费 " .. remaining .. "/" .. FREE_REFRESHES .. "）"
    else
        btnText = "🔄 刷新（💰" .. REFRESH_COST .. "）"
    end

    refreshContainer_:AddChild(UI.Button {
        text = btnText,
        fontSize = 13,
        width = 240,
        height = 38,
        variant = canAfford and "secondary" or "secondary",
        borderRadius = 8,
        disabled = not canAfford,
        backgroundColor = canAfford and { 50, 50, 70, 220 } or { 40, 40, 40, 180 },
        onClick = function(self)
            if not isFree then
                if not GameManager.SpendGold(REFRESH_COST) then
                    print("[LevelUpUI] 金币不足，无法刷新")
                    return
                end
                print("[LevelUpUI] 花费 " .. REFRESH_COST .. " 金币刷新技能")
            else
                print("[LevelUpUI] 免费刷新 (" .. (remaining - 1) .. " 次剩余)")
            end
            refreshCount_ = refreshCount_ + 1
            buildSkillCards()
        end,
    })

    -- 如果不免费，显示当前金币数
    if not isFree then
        refreshContainer_:AddChild(UI.Label {
            text = "  💰 " .. gold,
            fontSize = 12,
            fontColor = gold >= REFRESH_COST and { 255, 220, 80, 220 } or { 200, 80, 80, 220 },
            marginLeft = 8,
        })
    end
end

--- 创建技能选择卡片
buildSkillCards = function()
    UIHelper.DestroyChildren(cardsContainer_)

    local choices = LevelSystem.GetSkillChoices()
    local cardColors = {
        { 20, 50, 80 },    -- 蓝
        { 60, 30, 60 },    -- 紫
        { 80, 40, 20 },    -- 橙
    }

    -- 若没有可选技能
    if #choices == 0 then
        cardsContainer_:AddChild(UI.Label {
            text = "所有技能已解锁！",
            fontSize = 18,
            fontColor = { 255, 220, 80, 255 },
            marginTop = 20,
            marginBottom = 20,
        })
        -- 没有可选技能时直接提供关闭按钮
        cardsContainer_:AddChild(UI.Button {
            text = "继续",
            fontSize = 14,
            width = 120,
            height = 38,
            variant = "primary",
            borderRadius = 8,
            onClick = function(self)
                -- 消耗掉这次技能升级
                LevelSystem.ApplySkill({ id = "__skip__", name = "跳过", cooldown = 999 })
                LevelUpUI.OnChoiceMade()
            end,
        })
        -- 隐藏刷新按钮
        if refreshContainer_ then UIHelper.DestroyChildren(refreshContainer_) end
        return
    end

    for i, skill in ipairs(choices) do
        local bg = cardColors[i] or cardColors[1]

        local card = UI.Panel {
            width = 170,
            margin = 8,
            padding = 16,
            backgroundColor = { bg[1], bg[2], bg[3], 220 },
            borderRadius = 12,
            borderWidth = 2,
            borderColor = { 100, 180, 220, 120 },
            alignItems = "center",
            children = {
                -- 图标
                UI.Label {
                    text = skill.icon,
                    fontSize = 36,
                    marginBottom = 6,
                },
                -- 类型标签
                UI.Label {
                    text = skill.type,
                    fontSize = 10,
                    fontColor = { 120, 200, 255, 200 },
                    marginBottom = 4,
                },
                -- 名称
                UI.Label {
                    text = skill.name,
                    fontSize = 16,
                    fontWeight = "bold",
                    fontColor = { 255, 240, 200, 255 },
                    marginBottom = 6,
                },
                -- 描述
                UI.Label {
                    text = skill.desc,
                    fontSize = 11,
                    fontColor = { 200, 200, 200, 200 },
                    textAlign = "center",
                    marginBottom = 4,
                },
                -- 冷却信息
                UI.Label {
                    text = "冷却: " .. skill.cooldown .. "s",
                    fontSize = 10,
                    fontColor = { 160, 160, 180, 180 },
                    marginBottom = 12,
                },
                -- 选择按钮
                UI.Button {
                    text = "选择",
                    fontSize = 13,
                    width = 100,
                    height = 34,
                    variant = "primary",
                    borderRadius = 6,
                    onClick = function(self)
                        LevelSystem.ApplySkill(skill)
                        LevelUpUI.OnChoiceMade()
                    end,
                },
            },
        }
        cardsContainer_:AddChild(card)
    end

    -- 构建刷新按钮
    buildRefreshButton()
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

--- 显示升级选择界面
function LevelUpUI.Show()
    if not root_ then return end

    -- 确保鼠标光标可见（升级选择需要点击）
    input.mouseMode = MM_ABSOLUTE
    input.mouseVisible = true

    if LevelSystem.HasPendingSkillUp() then
        -- 技能选择（每10级）— 重置刷新计数
        refreshCount_ = 0
        if titleLabel_ then titleLabel_:SetText("技能觉醒！") end
        if subtitleLabel_ then subtitleLabel_:SetText("Lv." .. LevelSystem.GetLevel() .. " — 选择一个强力技能") end
        buildSkillCards()
    else
        -- 属性选择（普通升级）
        if titleLabel_ then titleLabel_:SetText("升级！") end
        if subtitleLabel_ then subtitleLabel_:SetText("Lv." .. LevelSystem.GetLevel() .. " — 选择一项属性加成") end
        buildAttributeCards()
    end

    root_:Show()
end

function LevelUpUI.Hide()
    if root_ then root_:Hide() end
    -- 恢复鼠标锁定（由 onSelectionDone_ 回调负责，此处兜底）
    input.mouseMode = MM_RELATIVE
    input.mouseVisible = false
end

--- 选择完毕后的内部处理
function LevelUpUI.OnChoiceMade()
    -- 检查是否还有待处理的升级
    if LevelSystem.HasPendingLevelUp() then
        -- 继续显示下一个选择
        LevelUpUI.Show()
    else
        -- 全部选完，关闭界面
        LevelUpUI.Hide()
        if onSelectionDone_ then onSelectionDone_() end
    end
end

--- 注册选择完成回调（恢复游戏状态）
---@param cb function
function LevelUpUI.OnSelectionDone(cb)
    onSelectionDone_ = cb
end

---@return table
function LevelUpUI.GetRoot()
    return root_
end

return LevelUpUI
