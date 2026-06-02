-- ============================================================================
-- HUD.lua — 增强版 HUD
-- 十字准星 + 交互提示 + 物品获取通知 + 状态信息
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local PlayerHealth = require("combat.PlayerHealth")
local EnemyManager = require("combat.EnemyManager")
local WeaponSystem = require("combat.WeaponSystem")
local LevelSystem = require("combat.LevelSystem")
local SkillSystem = require("combat.SkillSystem")
local EquipmentSystem = require("combat.EquipmentSystem")
local KillBonusSystem = require("combat.KillBonusSystem")
local QuestData = require("data.QuestData")
local UIHelper = require("ui.UIHelper")
local MobileControls = require("ui.MobileControls")
local AwakeningSystem = require("systems.AwakeningSystem")
local DifficultySystem = require("systems.DifficultySystem")
local UI = require("urhox-libs/UI")

local HUD = {}

-- UI 引用
local hudRoot_ = nil
local crosshair_ = nil
local interactHint_ = nil
local itemNotify_ = nil
local titleLabel_ = nil
-- controlsHint_ 已移除（操作提示改为 TutorialUI 新手引导）
local killCountLabel_ = nil
local scoreLabel_ = nil
local currencyLabel_ = nil
local attrPanel_ = nil
local attrCacheKey_ = ""  -- 属性加成变化检测缓存

-- 血条
local healthBarFill_ = nil
local healthText_ = nil

-- 受伤闪红
local damageFlash_ = nil
local damageFlashTimer_ = 0

-- 死亡界面已合并至 ResultScreen

-- 武器栏
local weaponIcon_ = nil
local weaponName_ = nil
local weaponCooldown_ = nil
local weaponBar_ = nil
local rightHandName_ = nil
local rightHandCd_ = nil

-- 物品栏（双行28格：上行16武器、下行6技能+2装备+4击杀信息）
local inventoryBar_ = nil
local inventorySlots_ = {}  -- 28个格子的引用
local INVENTORY_SLOTS = 28
local ROW1_COUNT = 16       -- 上行：武器
local ROW2_COUNT = 12       -- 下行：6技能+2装备+4击杀信息
local killInfoLabel_ = nil  -- 击杀信息标签
local orbRangeLabel_ = nil  -- 经验球拾取范围加成标签

-- 经验条 / 等级
local xpBarFill_ = nil
local xpText_ = nil
local levelText_ = nil

-- 觉醒等级
local awakeningIcon_ = nil
local awakeningLabel_ = nil

-- 难度等级
local difficultyIcon_ = nil
local difficultyLabel_ = nil

-- Boss 血条
local bossBarPanel_ = nil
local bossBarFill_ = nil
local bossNameLabel_ = nil
local bossHPText_ = nil

-- 计时器
local timerLabel_ = nil
local gameTime_ = 0

-- 物品通知状态
local notifyTimer_ = 0
local notifyDuration_ = 3.0

-- ============================================================================
-- 初始化
-- ============================================================================

---@param dialoguePanel table|nil 对话面板（可选，嵌入HUD）
---@return table HUD根面板
function HUD.Init(dialoguePanel)
    local children = {}

    -- 1. 十字准星
    crosshair_ = UI.Label {
        id = "crosshair",
        text = "+",
        fontSize = 22,
        fontColor = { 255, 255, 255, 180 },
        position = "absolute",
        top = "50%",
        left = "50%",
        marginTop = -12,
        marginLeft = -6,
        textAlign = "center",
    }
    table.insert(children, crosshair_)

    -- 2. 交互提示（准星下方）
    interactHint_ = UI.Panel {
        id = "interactHintPanel",
        position = "absolute",
        top = "55%",
        left = 0,
        right = 0,
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                padding = { 6, 14 },
                backgroundColor = { 0, 0, 0, 160 },
                borderRadius = 8,
                borderWidth = 1,
                borderColor = { 240, 210, 140, 150 },
                children = {
                    UI.Label {
                        id = "interactHintText",
                        text = "按 F 交互",
                        fontSize = 13,
                        fontColor = { 240, 220, 160, 255 },
                    },
                },
            },
        },
    }
    table.insert(children, interactHint_)

    -- 3. 顶部计时器（居中）
    local timerPanel = UI.Panel {
        id = "timerPanel",
        position = "absolute",
        top = 12,
        left = 0, right = 0,
        alignItems = "center",
        pointerEvents = "none",
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                padding = { 6, 16 },
                backgroundColor = { 0, 0, 0, 140 },
                borderRadius = 8,
                borderWidth = 1,
                borderColor = { 200, 200, 200, 60 },
                children = {
                    UI.Label {
                        text = "⏱",
                        fontSize = 16,
                        marginRight = 6,
                    },
                    UI.Label {
                        id = "timerText",
                        text = "00:00",
                        fontSize = 18,
                        fontWeight = "bold",
                        fontColor = { 255, 255, 255, 220 },
                    },
                },
            },
        },
    }
    table.insert(children, timerPanel)
    timerLabel_ = timerPanel:FindById("timerText")

    -- 3.5. Boss 血条（顶部居中，计时器下方）
    bossBarPanel_ = UI.Panel {
        id = "bossBarPanel",
        position = "absolute",
        top = 48,
        left = 0, right = 0,
        alignItems = "center",
        pointerEvents = "none",
        visible = false,
        children = {
            UI.Panel {
                alignItems = "center",
                padding = { 6, 16 },
                backgroundColor = { 40, 0, 0, 180 },
                borderRadius = 8,
                borderWidth = 1,
                borderColor = { 200, 50, 50, 180 },
                children = {
                    UI.Label {
                        id = "bossName",
                        text = "Boss",
                        fontSize = 12,
                        fontWeight = "bold",
                        fontColor = { 255, 80, 80, 255 },
                        marginBottom = 4,
                    },
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        children = {
                            UI.Panel {
                                width = 200,
                                height = 12,
                                backgroundColor = { 60, 20, 20, 220 },
                                borderRadius = 6,
                                children = {
                                    UI.Panel {
                                        id = "bossFill",
                                        width = 200,
                                        height = 12,
                                        backgroundColor = { 220, 40, 40, 255 },
                                        borderRadius = 6,
                                    },
                                },
                            },
                            UI.Label {
                                id = "bossHPText",
                                text = "",
                                fontSize = 10,
                                fontColor = { 255, 200, 200, 200 },
                                marginLeft = 8,
                            },
                        },
                    },
                },
            },
        },
    }
    table.insert(children, bossBarPanel_)
    bossNameLabel_ = bossBarPanel_:FindById("bossName")
    bossBarFill_ = bossBarPanel_:FindById("bossFill")
    bossHPText_ = bossBarPanel_:FindById("bossHPText")

    -- 4. 物品获取通知（顶部居中弹出）
    itemNotify_ = UI.Panel {
        id = "itemNotifyPanel",
        position = "absolute",
        top = 60,
        left = 0,
        right = 0,
        alignItems = "center",
        visible = false,
        children = {
            UI.Panel {
                padding = { 10, 20 },
                backgroundColor = { 30, 60, 30, 200 },
                borderRadius = 10,
                borderWidth = 1,
                borderColor = { 120, 200, 120, 180 },
                children = {
                    UI.Label {
                        id = "itemNotifyText",
                        text = "",
                        fontSize = 15,
                        fontColor = { 180, 255, 180, 255 },
                    },
                },
            },
        },
    }
    table.insert(children, itemNotify_)

    -- 4. 左上角击杀数 + 评分
    titleLabel_ = UI.Panel {
        position = "absolute",
        top = 12,
        left = 12,
        padding = { 8, 12 },
        backgroundColor = { 0, 0, 0, 100 },
        borderRadius = 6,
        children = {
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "💀",
                        fontSize = 13,
                        marginRight = 4,
                    },
                    UI.Label {
                        id = "killCountLabel",
                        text = "击杀: 0",
                        fontSize = 12,
                        fontColor = { 255, 200, 200, 220 },
                    },
                },
            },
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginTop = 4,
                children = {
                    UI.Label {
                        text = "⭐",
                        fontSize = 13,
                        marginRight = 4,
                    },
                    UI.Label {
                        id = "scoreLabel",
                        text = "评分: 0",
                        fontSize = 12,
                        fontColor = { 255, 220, 80, 220 },
                    },
                },
            },
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginTop = 4,
                children = {
                    UI.Label {
                        id = "currencyLabel",
                        text = "🪙0  🔮0",
                        fontSize = 12,
                        fontColor = { 255, 230, 140, 220 },
                    },
                },
            },
        },
    }
    table.insert(children, titleLabel_)

    -- 5. （操作提示已移至 TutorialUI 新手引导系统）

    -- 6. 状态栏（右上角，血条+经验条）
    local statusPanel = UI.Panel {
        position = "absolute",
        top = 16,
        right = 16,
        padding = { 8, 12 },
        backgroundColor = { 10, 10, 15, 160 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = { 60, 60, 80, 100 },
        children = {
            -- 等级 + 经验条
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginBottom = 6,
                children = {
                    UI.Label {
                        id = "levelBadge",
                        text = "Lv.1",
                        fontSize = 15,
                        fontWeight = "bold",
                        fontColor = { 255, 220, 80, 255 },
                        marginRight = 8,
                    },
                    UI.Panel {
                        width = 180,
                        height = 10,
                        backgroundColor = { 30, 30, 50, 220 },
                        borderRadius = 5,
                        children = {
                            UI.Panel {
                                id = "xpFill",
                                width = 0,
                                height = 10,
                                backgroundColor = { 80, 180, 255, 255 },
                                borderRadius = 5,
                            },
                        },
                    },
                    UI.Label {
                        id = "xpText",
                        text = "0/100",
                        fontSize = 11,
                        fontColor = { 160, 200, 255, 200 },
                        marginLeft = 8,
                    },
                },
            },
            -- 觉醒等级
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginBottom = 6,
                children = {
                    UI.Label {
                        id = "awakeningIcon",
                        text = "○",
                        fontSize = 14,
                        fontColor = { 140, 140, 160, 200 },
                        marginRight = 4,
                    },
                    UI.Label {
                        id = "awakeningLabel",
                        text = "未觉醒",
                        fontSize = 12,
                        fontColor = { 140, 140, 160, 200 },
                    },
                },
            },
            -- 难度等级
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginBottom = 6,
                children = {
                    UI.Label {
                        id = "difficultyIcon",
                        text = "⚔",
                        fontSize = 14,
                        fontColor = { 180, 180, 200, 200 },
                        marginRight = 4,
                    },
                    UI.Label {
                        id = "difficultyLabel",
                        text = "普通",
                        fontSize = 12,
                        fontColor = { 180, 180, 200, 200 },
                    },
                },
            },
            -- 血条
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "❤",
                        fontSize = 20,
                        fontColor = { 220, 50, 50, 255 },
                        marginRight = 8,
                    },
                    UI.Panel {
                        width = 200,
                        height = 16,
                        backgroundColor = { 40, 40, 40, 220 },
                        borderRadius = 8,
                        children = {
                            UI.Panel {
                                id = "healthFill",
                                width = 200,
                                height = 16,
                                backgroundColor = { 80, 200, 80, 255 },
                                borderRadius = 8,
                            },
                        },
                    },
                    UI.Label {
                        id = "healthText",
                        text = "100/100",
                        fontSize = 13,
                        fontColor = { 255, 255, 255, 220 },
                        marginLeft = 8,
                    },
                },
            },
        },
    }
    table.insert(children, statusPanel)
    healthBarFill_ = statusPanel:FindById("healthFill")
    healthText_ = statusPanel:FindById("healthText")
    xpBarFill_ = statusPanel:FindById("xpFill")
    xpText_ = statusPanel:FindById("xpText")
    levelText_ = statusPanel:FindById("levelBadge")
    awakeningIcon_ = statusPanel:FindById("awakeningIcon")
    awakeningLabel_ = statusPanel:FindById("awakeningLabel")
    difficultyIcon_ = statusPanel:FindById("difficultyIcon")
    difficultyLabel_ = statusPanel:FindById("difficultyLabel")


    -- 7. 受伤闪红（全屏）
    damageFlash_ = UI.Panel {
        id = "damageFlash",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        backgroundColor = { 200, 0, 0, 0 },
        pointerEvents = "none",
        visible = false,
    }
    table.insert(children, damageFlash_)

    -- 8. 死亡界面已合并至 ResultScreen（此处已移除）

    -- 9. 物品栏（底部居中，双行28格 + 武器信息）
    inventorySlots_ = {}

    -- 创建格子的辅助函数
    local function makeSlot(idx, size)
        size = size or 34
        local slotId = "invSlot" .. idx
        local slot = UI.Panel {
            id = slotId,
            width = size, height = size,
            margin = 1,
            backgroundColor = { 30, 30, 40, 180 },
            borderRadius = 4,
            borderWidth = 1,
            borderColor = { 80, 80, 100, 120 },
            justifyContent = "center",
            alignItems = "center",
            children = {
                UI.Label {
                    id = slotId .. "_icon",
                    text = "",
                    fontSize = 16,
                },
                UI.Label {
                    id = slotId .. "_num",
                    text = "",
                    fontSize = 7,
                    fontColor = { 160, 160, 180, 120 },
                    position = "absolute",
                    top = 1, left = 2,
                },
            },
        }
        inventorySlots_[idx] = slot
        return slot
    end

    -- 上行：16个武器格子
    local row1Children = {}
    for i = 1, ROW1_COUNT do
        table.insert(row1Children, makeSlot(i, 34))
    end

    -- 下行：6技能 + 2装备 + 击杀信息面板
    local row2Children = {}
    for i = 1, 6 do
        table.insert(row2Children, makeSlot(ROW1_COUNT + i, 34))
    end
    -- 分隔线
    table.insert(row2Children, UI.Panel {
        width = 1, height = 28, backgroundColor = { 80, 80, 100, 80 },
        marginLeft = 3, marginRight = 3,
    })
    for i = 1, 2 do
        table.insert(row2Children, makeSlot(ROW1_COUNT + 6 + i, 34))
    end
    -- 分隔线
    table.insert(row2Children, UI.Panel {
        width = 1, height = 28, backgroundColor = { 80, 80, 100, 80 },
        marginLeft = 3, marginRight = 3,
    })
    -- 击杀加成信息面板
    local killInfoPanel = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        padding = { 2, 6 },
        backgroundColor = { 20, 15, 30, 180 },
        borderRadius = 4,
        borderWidth = 1,
        borderColor = { 120, 60, 180, 120 },
        height = 34,
        gap = 4,
        children = {
            UI.Label {
                id = "killInfoLabel",
                text = "x0",
                fontSize = 10,
                fontColor = { 200, 160, 255, 220 },
            },
            UI.Label {
                id = "orbRangeLabel",
                text = "",
                fontSize = 9,
                fontColor = { 100, 220, 255, 200 },
            },
        },
    }
    table.insert(row2Children, killInfoPanel)

    inventoryBar_ = UI.Panel {
        id = "inventoryBar",
        position = "absolute",
        bottom = 6,
        left = 0, right = 0,
        alignItems = "center",
        pointerEvents = "none",
        children = {
            -- 双手武器信息提示行
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginBottom = 3,
                children = {
                    -- 右手（剑）
                    UI.Label {
                        text = "🗡",
                        fontSize = 14,
                    },
                    UI.Label {
                        id = "rightHandName",
                        text = "铁剑",
                        fontSize = 11,
                        fontWeight = "bold",
                        fontColor = { 240, 230, 200, 255 },
                        marginLeft = 4,
                    },
                    UI.Label {
                        id = "rightHandCd",
                        text = "",
                        fontSize = 9,
                        fontColor = { 200, 160, 100, 200 },
                        marginLeft = 4,
                    },
                    -- 分隔
                    UI.Label {
                        text = " │ ",
                        fontSize = 11,
                        fontColor = { 120, 120, 130, 120 },
                    },
                    -- 左手（道具/技能）
                    UI.Label {
                        id = "weaponIcon",
                        text = "",
                        fontSize = 14,
                    },
                    UI.Label {
                        id = "weaponName",
                        text = "",
                        fontSize = 11,
                        fontWeight = "bold",
                        fontColor = { 200, 220, 255, 255 },
                        marginLeft = 4,
                    },
                    UI.Label {
                        id = "weaponCooldown",
                        text = "",
                        fontSize = 9,
                        fontColor = { 160, 180, 220, 200 },
                        marginLeft = 4,
                    },
                    UI.Label {
                        id = "weaponSwitchHint",
                        text = "  Q ◀ ▶ E",
                        fontSize = 9,
                        fontColor = { 160, 160, 170, 100 },
                        marginLeft = 6,
                    },
                },
            },
            -- 上行：武器格子
            UI.Panel {
                flexDirection = "row",
                backgroundColor = { 10, 10, 15, 200 },
                borderRadius = 6,
                borderWidth = 1,
                borderColor = { 60, 60, 80, 150 },
                padding = { 2, 3 },
                marginBottom = 2,
                children = row1Children,
            },
            -- 下行：技能+装备+击杀
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                backgroundColor = { 10, 10, 15, 200 },
                borderRadius = 6,
                borderWidth = 1,
                borderColor = { 60, 60, 80, 150 },
                padding = { 2, 3 },
                children = row2Children,
            },
        },
    }
    table.insert(children, inventoryBar_)
    weaponIcon_ = inventoryBar_:FindById("weaponIcon")
    weaponName_ = inventoryBar_:FindById("weaponName")
    weaponCooldown_ = inventoryBar_:FindById("weaponCooldown")
    rightHandName_ = inventoryBar_:FindById("rightHandName")
    rightHandCd_ = inventoryBar_:FindById("rightHandCd")
    killInfoLabel_ = inventoryBar_:FindById("killInfoLabel")
    orbRangeLabel_ = inventoryBar_:FindById("orbRangeLabel")

    -- 9.5 属性加成面板（血条下方，多列纵向排列）
    attrPanel_ = UI.Panel {
        id = "attrPanel",
        position = "absolute",
        top = 115,
        right = 16,
        padding = { 6, 10 },
        backgroundColor = { 10, 10, 15, 180 },
        borderRadius = 6,
        borderWidth = 1,
        borderColor = { 60, 60, 80, 100 },
        pointerEvents = "none",
        visible = false,
        flexDirection = "row",
        alignItems = "flex-start",
        children = {},
    }
    table.insert(children, attrPanel_)

    -- 10. 嵌入对话面板（如果有）
    if dialoguePanel then
        table.insert(children, dialoguePanel)
    end

    -- 获取击杀/评分标签引用
    killCountLabel_ = titleLabel_:FindById("killCountLabel")
    scoreLabel_ = titleLabel_:FindById("scoreLabel")
    currencyLabel_ = titleLabel_:FindById("currencyLabel")

    -- 创建HUD根面板
    hudRoot_ = UI.Panel {
        id = "gameHUD",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = children,
    }

    print("[HUD] 初始化完成")
    return hudRoot_
end

-- ============================================================================
-- 交互提示控制
-- ============================================================================

--- 显示交互提示
---@param targetType string "npc"|"item"|"sign"|"examine"
---@param targetName string|nil 目标名称
function HUD.ShowInteractHint(targetType, targetName)
    if not interactHint_ then return end

    local isMobile = MobileControls.IsMobileMode()
    local key = isMobile and "点击" or "按 F"
    local hintText = key .. " 交互"
    if targetType == "npc" then
        hintText = key .. " 与" .. (targetName or "???") .. "对话"
    elseif targetType == "item" then
        hintText = key .. " 拾取"
    elseif targetType == "equipment" then
        hintText = key .. " 拾取装备"
    elseif targetType == "sign" then
        hintText = key .. " 查看"
    elseif targetType == "examine" then
        hintText = key .. " 调查"
    elseif targetType == "door" then
        hintText = key .. " 开/关门"
    end

    local textWidget = interactHint_:FindById("interactHintText")
    if textWidget then
        textWidget:SetText(hintText)
    end
    interactHint_:Show()

    -- 准星变为黄色
    if crosshair_ then
        crosshair_:SetStyle({ fontColor = { 240, 220, 140, 255 } })
    end
end

--- 隐藏交互提示
function HUD.HideInteractHint()
    if interactHint_ then
        interactHint_:Hide()
    end
    -- 准星恢复白色
    if crosshair_ then
        crosshair_:SetStyle({ fontColor = { 255, 255, 255, 180 } })
    end
end

-- ============================================================================
-- 物品获取通知
-- ============================================================================

--- 显示物品获取通知
---@param itemId string
function HUD.ShowItemNotify(itemId)
    if not itemNotify_ then return end

    local info = QuestData.GetItemInfo(itemId)
    local name = info and info.name or itemId

    local textWidget = itemNotify_:FindById("itemNotifyText")
    if textWidget then
        textWidget:SetText("获得物品：" .. name)
    end

    itemNotify_:Show()
    notifyTimer_ = notifyDuration_
end

--- 显示装备获得通知
---@param equipId string
function HUD.ShowEquipNotify(equipId)
    if not itemNotify_ then return end
    local eqCfg = GameConfig.Equipment[equipId]
    local name = eqCfg and (eqCfg.icon .. " " .. eqCfg.name) or equipId
    local textWidget = itemNotify_:FindById("itemNotifyText")
    if textWidget then
        textWidget:SetText("获得装备：" .. name)
    end
    itemNotify_:Show()
    notifyTimer_ = notifyDuration_
end

--- 通用通知（商店/兑换等场景使用）
---@param msg string
---@param color? table {r,g,b,a}
function HUD.ShowNotification(msg, color)
    if not itemNotify_ then return end
    local textWidget = itemNotify_:FindById("itemNotifyText")
    if textWidget then
        textWidget:SetText(msg or "")
        if color then
            textWidget:SetStyle({ fontColor = color })
        end
    end
    itemNotify_:Show()
    notifyTimer_ = notifyDuration_
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

-- 缓存上一帧的移动模式状态，避免每帧重复操作
local lastMobileMode_ = nil

---@param dt number
function HUD.Update(dt)
    -- 移动模式适配：更新武器切换提示文本
    local isMobile = MobileControls.IsMobileMode()
    if isMobile ~= lastMobileMode_ then
        lastMobileMode_ = isMobile
        -- 武器切换提示
        if hudRoot_ then
            local switchHint = hudRoot_:FindById("weaponSwitchHint")
            if switchHint then
                switchHint:SetText(isMobile and "  ◀ ▶" or "  Q ◀ ▶ E")
            end
        end
    end

    -- 更新计时器（仅在 PLAYING 状态）
    if GameManager.GetState() == GameConfig.States.PLAYING then
        gameTime_ = gameTime_ + dt
    end
    if timerLabel_ then
        local m = math.floor(gameTime_ / 60)
        local s = math.floor(gameTime_ % 60)
        timerLabel_:SetText(string.format("%02d:%02d", m, s))
    end

    -- 物品通知淡出计时
    if notifyTimer_ > 0 then
        notifyTimer_ = notifyTimer_ - dt
        if notifyTimer_ <= 0 then
            if itemNotify_ then
                itemNotify_:Hide()
            end
        end
    end

    -- 更新击杀数和评分
    local kills = EnemyManager.GetKillCount()
    if killCountLabel_ then
        killCountLabel_:SetText("击杀: " .. kills)
    end
    if scoreLabel_ then
        local level = LevelSystem.GetLevel()
        local score = math.floor(gameTime_ / 60) * 10 + kills + level * 20
        scoreLabel_:SetText("评分: " .. score)
    end
    if currencyLabel_ then
        currencyLabel_:SetText("🪙" .. GameManager.GetGold() .. "  🔮" .. GameManager.GetCrystal())
    end

    -- 更新血条
    local hp = PlayerHealth.GetHP()
    local maxHP = PlayerHealth.GetMaxHP()
    if healthBarFill_ then
        local fillW = math.floor(200 * hp / maxHP)
        local r, g
        local pct = hp / maxHP
        if pct > 0.5 then
            r, g = 80, 200
        elseif pct > 0.25 then
            r, g = 220, 180
        else
            r, g = 200, 50
        end
        healthBarFill_:SetStyle({ width = fillW, backgroundColor = { r, g, 50, 255 } })
    end
    if healthText_ then
        healthText_:SetText(math.floor(hp) .. "/" .. math.floor(maxHP))
    end

    -- 更新经验条和等级
    if xpBarFill_ then
        local xp = LevelSystem.GetXP()
        local xpNext = LevelSystem.GetXPToNext()
        local fillW = math.floor(180 * xp / math.max(1, xpNext))
        xpBarFill_:SetStyle({ width = fillW })
    end
    if xpText_ then
        xpText_:SetText(LevelSystem.GetXP() .. "/" .. LevelSystem.GetXPToNext())
    end
    if levelText_ then
        levelText_:SetText("Lv." .. LevelSystem.GetLevel())
    end

    -- 更新觉醒等级
    if awakeningLabel_ then
        local awkLv = AwakeningSystem.GetLevel()
        local clr = AwakeningSystem.GetLevelColor()
        local icon = AwakeningSystem.GetLevelIcon()
        local name = AwakeningSystem.GetLevelName()
        awakeningLabel_:SetText(name)
        awakeningLabel_:SetStyle({ fontColor = { clr[1], clr[2], clr[3], 255 } })
        if awakeningIcon_ then
            awakeningIcon_:SetText(icon)
            awakeningIcon_:SetStyle({ fontColor = { clr[1], clr[2], clr[3], 255 } })
        end
    end

    -- 更新难度等级
    if difficultyLabel_ then
        local diffName = DifficultySystem.GetName()
        local diffIcon = DifficultySystem.GetIcon()
        local diffColor = DifficultySystem.GetColor()
        difficultyLabel_:SetText(diffName)
        difficultyLabel_:SetStyle({ fontColor = { diffColor[1], diffColor[2], diffColor[3], 255 } })
        if difficultyIcon_ then
            difficultyIcon_:SetText(diffIcon)
            difficultyIcon_:SetStyle({ fontColor = { diffColor[1], diffColor[2], diffColor[3], 255 } })
        end
    end

    -- 更新双手武器信息栏
    -- 右手（剑）
    if rightHandName_ then
        local swordCfg = GameConfig.Weapons["iron_sword"]
        if swordCfg then
            rightHandName_:SetText(swordCfg.name)
            local swordCd = WeaponSystem.GetCooldown("iron_sword")
            if rightHandCd_ then
                if swordCd > 0 then
                    rightHandCd_:SetText(string.format("%.1fs", swordCd))
                else
                    rightHandCd_:SetText("右键")
                end
            end
        end
    end
    -- 左手（道具/技能）
    if weaponIcon_ and weaponName_ then
        local slotType = WeaponSystem.GetCurrentSlotType()
        if slotType == "skill" then
            local skillSlot = WeaponSystem.GetCurrentSkillSlot()
            local slotInfo = SkillSystem.GetSlotInfo()
            local info = slotInfo[skillSlot]
            if info then
                weaponIcon_:SetText(info.icon)
                weaponName_:SetText(info.name)
                if info.cooldown > 0 then
                    weaponCooldown_:SetText(string.format("%.1fs", info.cooldown))
                else
                    weaponCooldown_:SetText("左键")
                end
            end
        else
            local wid = WeaponSystem.GetLeftHandWeaponId()
            if wid then
                local cfg = GameConfig.Weapons[wid]
                if cfg then
                    weaponIcon_:SetText(cfg.icon)
                    weaponName_:SetText(cfg.name)
                    local cd = WeaponSystem.GetCooldown(wid)
                    if cd > 0 then
                        weaponCooldown_:SetText(string.format("%.1fs", cd))
                    else
                        weaponCooldown_:SetText("左键")
                    end
                end
            else
                weaponIcon_:SetText("")
                weaponName_:SetText("无道具")
                weaponCooldown_:SetText("")
            end
        end
    end

    -- 更新物品栏（28格双行：上行16武器、下行6技能+2装备+击杀信息）
    if #inventorySlots_ > 0 then
        local order = GameConfig.Weapons.Order
        local leftWid = WeaponSystem.GetLeftHandWeaponId()
        for i = 1, INVENTORY_SLOTS do
            local slot = inventorySlots_[i]
            if not slot then goto continue_slot end
            local iconLabel = slot:FindById("invSlot" .. i .. "_icon")
            local numLabel = slot:FindById("invSlot" .. i .. "_num")

            if i <= ROW1_COUNT then
                -- ===== 上行1~16格：武器/物品槽 =====
                if i <= #order then
                    local itemId = order[i]
                    local wCfg = GameConfig.Weapons[itemId]
                    if numLabel then numLabel:SetText(tostring(i <= 9 and i or "")) end

                    if GameManager.HasItem(itemId) then
                        if iconLabel then iconLabel:SetText(wCfg and wCfg.icon or "?") end
                        if itemId == "iron_sword" then
                            slot:SetStyle({
                                backgroundColor = { 50, 25, 20, 220 },
                                borderColor = { 240, 120, 80, 255 },
                                borderWidth = 2,
                            })
                        elseif itemId == leftWid then
                            slot:SetStyle({
                                backgroundColor = { 60, 50, 20, 220 },
                                borderColor = { 240, 200, 80, 255 },
                                borderWidth = 2,
                            })
                        else
                            slot:SetStyle({
                                backgroundColor = { 40, 40, 55, 200 },
                                borderColor = { 100, 100, 130, 150 },
                                borderWidth = 1,
                            })
                        end
                    else
                        if iconLabel then iconLabel:SetText("") end
                        slot:SetStyle({
                            backgroundColor = { 20, 20, 30, 160 },
                            borderColor = { 60, 60, 70, 100 },
                            borderWidth = 1,
                        })
                    end
                else
                    -- 超出武器数量的空位
                    if iconLabel then iconLabel:SetText("") end
                    if numLabel then numLabel:SetText("") end
                    slot:SetStyle({
                        backgroundColor = { 15, 15, 20, 120 },
                        borderColor = { 40, 40, 50, 60 },
                        borderWidth = 1,
                    })
                end

            elseif i <= ROW1_COUNT + 6 then
                -- ===== 下行17~22格：技能槽位（1-6） =====
                local skillSlots = SkillSystem.GetSlotInfo()
                local si = i - ROW1_COUNT  -- 1~6
                local info = skillSlots[si]
                if numLabel then numLabel:SetText(info and info.keyLabel or "") end
                local isSkillSelected = (WeaponSystem.GetCurrentSlotType() == "skill" and WeaponSystem.GetCurrentSkillSlot() == si)

                if info and info.unlocked then
                    if isSkillSelected then
                        if info.cooldown > 0 then
                            if iconLabel then iconLabel:SetText(string.format("%.0f", math.ceil(info.cooldown))) end
                        else
                            if iconLabel then iconLabel:SetText(info.icon) end
                        end
                        slot:SetStyle({
                            backgroundColor = { 60, 50, 20, 220 },
                            borderColor = { 240, 200, 80, 255 },
                            borderWidth = 2,
                        })
                    elseif info.cooldown > 0 then
                        if iconLabel then iconLabel:SetText(string.format("%.0f", math.ceil(info.cooldown))) end
                        slot:SetStyle({
                            backgroundColor = { 25, 25, 40, 200 },
                            borderColor = { 80, 80, 120, 150 },
                            borderWidth = 1,
                        })
                    else
                        if iconLabel then iconLabel:SetText(info.icon) end
                        slot:SetStyle({
                            backgroundColor = { 30, 40, 60, 220 },
                            borderColor = { 80, 160, 255, 220 },
                            borderWidth = 2,
                        })
                    end
                else
                    if iconLabel then iconLabel:SetText("🔒") end
                    slot:SetStyle({
                        backgroundColor = { 20, 20, 30, 140 },
                        borderColor = { 50, 50, 60, 80 },
                        borderWidth = 1,
                    })
                end

            elseif i <= ROW1_COUNT + 8 then
                -- ===== 下行23~24格：装备槽 =====
                local eqSlot = i - ROW1_COUNT - 6  -- 1 或 2
                local equipped = EquipmentSystem.GetEquipped()
                local eqId = equipped[eqSlot]
                if numLabel then numLabel:SetText("E" .. eqSlot) end

                if eqId then
                    local eqCfg = GameConfig.Equipment[eqId]
                    if iconLabel then iconLabel:SetText(eqCfg and eqCfg.icon or "⚔") end
                    slot:SetStyle({
                        backgroundColor = { 40, 25, 50, 220 },
                        borderColor = { 180, 100, 220, 255 },
                        borderWidth = 2,
                    })
                else
                    if iconLabel then iconLabel:SetText("") end
                    slot:SetStyle({
                        backgroundColor = { 20, 20, 30, 120 },
                        borderColor = { 50, 50, 60, 80 },
                        borderWidth = 1,
                    })
                end
            end
            ::continue_slot::
        end
    end

    -- 更新击杀加成信息
    if killInfoLabel_ then
        local tier = KillBonusSystem.GetKillTier()
        local passives = KillBonusSystem.GetPassiveSkills()
        local passiveIcons = ""
        if passives then
            for _, p in ipairs(passives) do
                if p.unlocked then
                    passiveIcons = passiveIcons .. p.icon
                end
            end
        end
        if tier > 0 then
            killInfoLabel_:SetText("x" .. tier .. " " .. passiveIcons)
        else
            killInfoLabel_:SetText("x0")
        end
    end

    -- 更新经验球拾取范围加成
    if orbRangeLabel_ then
        local orbTier = KillBonusSystem.GetOrbRangeTier()
        if orbTier > 0 then
            orbRangeLabel_:SetText("🧲+" .. orbTier .. "%")
        else
            orbRangeLabel_:SetText("")
        end
    end

    -- 更新属性加成面板（多列纵向排列）
    if attrPanel_ then
        local bonuses = LevelSystem.GetBonuses()
        local activeAttrs = {}
        local attrDefs = {
            { id = "attackSpeed", icon = "⚡", fmt = "攻速+%d%%"  },
            { id = "maxHP",       icon = "❤", fmt = "生命+%d"    },
            { id = "cooldown",    icon = "🔄", fmt = "冷却-%d%%"  },
            { id = "range",       icon = "🎯", fmt = "范围+%d%%"  },
            { id = "count",       icon = "💥", fmt = "多重+%d"    },
            { id = "attackSize",  icon = "🔶", fmt = "面积+%d%%"  },
            { id = "attackCount", icon = "🔱", fmt = "弹体+%d"    },
        }
        for _, def in ipairs(attrDefs) do
            local val = bonuses[def.id] or 0
            if val > 0 then
                table.insert(activeAttrs, def.icon .. string.format(def.fmt, val))
            end
        end
        local newKey = table.concat(activeAttrs, "|")
        if #activeAttrs > 0 and newKey ~= attrCacheKey_ then
            attrCacheKey_ = newKey
            UIHelper.DestroyChildren(attrPanel_)
            -- 每列最多3项，按列分组
            local maxPerCol = 3
            local colCount = math.ceil(#activeAttrs / maxPerCol)
            local idx = 1
            for c = 1, colCount do
                local colItems = {}
                for r = 1, maxPerCol do
                    if idx <= #activeAttrs then
                        table.insert(colItems, UI.Label {
                            text = activeAttrs[idx],
                            fontSize = 11,
                            fontColor = { 220, 220, 240, 220 },
                        })
                        idx = idx + 1
                    end
                end
                attrPanel_:AddChild(UI.Panel {
                    flexDirection = "column",
                    marginRight = c < colCount and 10 or 0,
                    children = colItems,
                })
            end
            attrPanel_:Show()
        elseif #activeAttrs == 0 and attrCacheKey_ ~= "" then
            attrCacheKey_ = ""
            UIHelper.DestroyChildren(attrPanel_)
            attrPanel_:Hide()
        end
    end

    -- 更新 Boss 血条
    if bossBarPanel_ then
        local bossHP, bossMaxHP, bossName = EnemyManager.GetActiveBossHP()
        if bossHP and bossMaxHP then
            bossBarPanel_:Show()
            if bossNameLabel_ then bossNameLabel_:SetText(bossName or "Boss") end
            if bossBarFill_ then
                local fillW = math.max(0, math.floor(200 * bossHP / math.max(1, bossMaxHP)))
                bossBarFill_:SetStyle({ width = fillW })
            end
            if bossHPText_ then
                bossHPText_:SetText(math.floor(bossHP) .. "/" .. math.floor(bossMaxHP))
            end
        else
            bossBarPanel_:Hide()
        end
    end

    -- 受伤闪红渐消
    if damageFlashTimer_ > 0 then
        damageFlashTimer_ = damageFlashTimer_ - dt
        local alpha = math.max(0, math.floor(120 * damageFlashTimer_ / 0.3))
        if damageFlash_ then
            damageFlash_:SetStyle({ backgroundColor = { 200, 0, 0, alpha } })
        end
        if damageFlashTimer_ <= 0 and damageFlash_ then
            damageFlash_:Hide()
        end
    end
end

-- ============================================================================
-- 准星显示/隐藏（进入UI时隐藏）
-- ============================================================================

function HUD.SetCrosshairVisible(visible)
    if crosshair_ then
        crosshair_:SetVisible(visible)
    end
end

---@return table
function HUD.GetRoot()
    return hudRoot_
end

-- ============================================================================
-- 战斗 UI
-- ============================================================================

function HUD.ShowDamageFlash()
    if damageFlash_ then
        damageFlash_:Show()
        damageFlash_:SetStyle({ backgroundColor = { 200, 0, 0, 120 } })
        damageFlashTimer_ = 0.3
    end
end

-- 死亡界面已合并至 ResultScreen，相关函数已移除

--- 获取当前游戏时间（秒）
---@return number
function HUD.GetGameTime()
    return gameTime_
end

--- 设置游戏时间（开发者用）
---@param t number 秒
function HUD.SetGameTime(t)
    gameTime_ = math.max(0, t)
end

--- 重置计时器（新游戏时调用）
function HUD.ResetTimer()
    gameTime_ = 0
end

return HUD
