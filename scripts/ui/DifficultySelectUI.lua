-- ============================================================================
-- DifficultySelectUI.lua — 出征难度选择界面
-- 离开安全区时弹出，选择本次出征的难度等级
-- ============================================================================

local DifficultySystem = require("systems.DifficultySystem")
local UI = require("urhox-libs/UI")

local DifficultySelectUI = {}

local root_ = nil
local onSelect_ = nil  -- 选择回调: cb(level)

-- ============================================================================
-- 初始化
-- ============================================================================

---@return table UI 面板
function DifficultySelectUI.Init()
    local cardsRow = UI.Panel {
        id = "diffCards",
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "flex-start",
        flexWrap = "wrap",
        marginBottom = 20,
    }

    -- 4个难度卡片
    for i = 1, 4 do
        local cfg = DifficultySystem.Levels[i]
        local clr = cfg.color
        local isRecommended = (i == 2)

        local cardChildren = {
            UI.Label {
                text = cfg.icon,
                fontSize = 32,
                marginBottom = 6,
            },
            UI.Label {
                text = cfg.name,
                fontSize = 20,
                fontWeight = "bold",
                fontColor = { clr[1], clr[2], clr[3], 255 },
                marginBottom = 4,
            },
        }

        if isRecommended then
            table.insert(cardChildren, UI.Label {
                text = "推荐",
                fontSize = 11,
                fontColor = { 255, 220, 80, 220 },
                marginBottom = 4,
            })
        end

        table.insert(cardChildren, UI.Label {
            text = cfg.desc,
            fontSize = 11,
            fontColor = { 180, 180, 200, 180 },
            marginBottom = 8,
            textAlign = "center",
        })

        -- 倍率信息
        local infoText = ""
        if cfg.xpMult ~= 1.0 then
            infoText = infoText .. "经验x" .. cfg.xpMult .. " "
        end
        if cfg.goldMult ~= 1.0 then
            infoText = infoText .. "金币x" .. cfg.goldMult
        end
        if cfg.dropRarityBonus > 0 then
            infoText = infoText .. "\n稀有+" .. cfg.dropRarityBonus
        end
        if infoText ~= "" then
            table.insert(cardChildren, UI.Label {
                text = infoText,
                fontSize = 10,
                fontColor = { 140, 200, 255, 160 },
                marginBottom = 8,
                textAlign = "center",
            })
        end

        local lvl = i
        table.insert(cardChildren, UI.Button {
            text = "选择",
            fontSize = 13,
            width = 80,
            height = 30,
            variant = (i == 2) and "primary" or "outline",
            borderRadius = 15,
            onClick = function()
                DifficultySystem.SetLevel(lvl)
                -- 先保存回调引用，Hide 会清空 onSelect_
                local cb = onSelect_
                DifficultySelectUI.Hide()
                if cb then cb(lvl) end
            end,
        })

        local borderClr = { clr[1], clr[2], clr[3], 100 }
        cardsRow:AddChild(UI.Panel {
            width = 150,
            padding = { 14, 12 },
            margin = { 0, 6, 0, 6 },
            backgroundColor = { 25, 20, 45, 220 },
            borderRadius = 12,
            borderWidth = isRecommended and 2 or 1,
            borderColor = isRecommended and { 255, 220, 80, 180 } or borderClr,
            alignItems = "center",
            children = cardChildren,
        })
    end

    root_ = UI.Panel {
        id = "difficultySelectOverlay",
        position = "absolute",
        left = 0, right = 0, top = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 180 },
        visible = false,
        children = {
            UI.Panel {
                backgroundColor = { 15, 12, 30, 240 },
                borderRadius = 16,
                borderWidth = 2,
                borderColor = { 120, 80, 200, 150 },
                padding = { 24, 28 },
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "选择出征难度",
                        fontSize = 28,
                        fontWeight = "bold",
                        fontColor = { 220, 200, 255, 240 },
                        marginBottom = 8,
                    },
                    UI.Label {
                        text = "难度越高，掉落越稀有，奖励越丰厚",
                        fontSize = 14,
                        fontColor = { 160, 160, 180, 180 },
                        marginBottom = 24,
                    },
                    cardsRow,
                },
            },
        },
    }

    print("[DifficultySelectUI] 初始化完成")
    return root_
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

---@param onSelect function(level) 选择回调
function DifficultySelectUI.Show(onSelect)
    onSelect_ = onSelect
    if root_ then root_:Show() end
end

function DifficultySelectUI.Hide()
    if root_ then root_:Hide() end
    onSelect_ = nil
end

function DifficultySelectUI.IsVisible()
    return root_ and root_:IsVisible() or false
end

return DifficultySelectUI
