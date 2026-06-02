-- ============================================================================
-- DialogueUI.lua — 对话界面
-- 底部对话框显示NPC对话，支持逐字显示和按键翻页
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local QuestData = require("data.QuestData")
local FirstPersonController = require("core.FirstPersonController")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local DialogueUI = {}

-- 状态
local isActive_ = false
local currentDialogue_ = nil    -- 对话列表
local currentIndex_ = 0         -- 当前对话索引
local currentNpcId_ = nil       -- 当前NPC ID
local displayedText_ = ""       -- 已显示的文字
local fullText_ = ""            -- 完整文字
local charTimer_ = 0            -- 逐字计时
local charSpeed_ = 0.03         -- 每个字的间隔(秒)
local isTextComplete_ = false   -- 当前条文字是否显示完毕

-- UI 引用
local dialogueRoot_ = nil
local speakerLabel_ = nil
local textLabel_ = nil
local hintLabel_ = nil

-- 按钮栏引用
local btnBar_ = nil

-- 回调
local onDialogueEnd_ = nil

-- ============================================================================
-- 初始化 UI
-- ============================================================================

function DialogueUI.Init()
    -- 对话框根面板（底部弹出）
    -- 按钮栏（跳过 + 商店/兑换，根据 NPC 动态显示）
    btnBar_ = UI.Panel {
        id = "dialogueBtnBar",
        flexDirection = "row",
        justifyContent = "flex-end",
        alignItems = "center",
        marginTop = 6,
        gap = 8,
    }

    dialogueRoot_ = UI.Panel {
        id = "dialoguePanel",
        position = "absolute",
        bottom = 20,
        left = "5%",
        right = "5%",
        backgroundColor = { 15, 15, 25, 220 },
        borderRadius = 12,
        borderWidth = 2,
        borderColor = { 180, 160, 120, 200 },
        padding = { 16, 20 },
        visible = false,  -- 默认隐藏
        children = {
            -- 顶部行：说话者名字
            UI.Label {
                id = "speakerName",
                text = "",
                fontSize = 16,
                fontWeight = "bold",
                fontColor = { 240, 210, 140, 255 },
                marginBottom = 8,
            },
            -- 对话内容
            UI.Label {
                id = "dialogueText",
                text = "",
                fontSize = 14,
                fontColor = { 230, 230, 230, 255 },
                lineHeight = 1.5,
                marginBottom = 10,
            },
            -- 底部行：翻页提示 + 按钮栏
            UI.Panel {
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                children = {
                    UI.Label {
                        id = "dialogueHint",
                        text = "▼ 点击或按空格继续",
                        fontSize = 11,
                        fontColor = { 180, 180, 180, 140 },
                    },
                    btnBar_,
                },
            },
        },
    }

    -- 缓存子控件引用
    speakerLabel_ = dialogueRoot_:FindById("speakerName")
    textLabel_ = dialogueRoot_:FindById("dialogueText")
    hintLabel_ = dialogueRoot_:FindById("dialogueHint")

    print("[DialogueUI] 初始化完成")
    return dialogueRoot_
end

-- ============================================================================
-- 设置回调
-- ============================================================================

---@param callback function()
function DialogueUI.OnDialogueEnd(callback)
    onDialogueEnd_ = callback
end

-- ============================================================================
-- 构建按钮栏（根据 NPC 特性动态添加按钮）
-- ============================================================================

local function rebuildBtnBar(npcId)
    if not btnBar_ then return end
    UIHelper.DestroyChildren(btnBar_)

    local features = GameConfig.NPCFeatures and GameConfig.NPCFeatures[npcId] or {}

    -- 商店按钮（仅特定 NPC）
    if features.shop then
        btnBar_:AddChild(UI.Button {
            text = "💰 商店",
            fontSize = 12,
            height = 30,
            paddingLeft = 10,
            paddingRight = 10,
            borderRadius = 6,
            backgroundColor = { 180, 150, 50, 220 },
            fontColor = { 20, 18, 10, 255 },
            onClick = function()
                DialogueUI.EndDialogue()
                local ok, ShopUI = pcall(require, "ui.ShopUI")
                if ok and ShopUI then
                    local HUD = require("ui.HUD")
                    HUD.SetCrosshairVisible(false)
                    ShopUI.Show()
                end
            end,
        })
    end

    -- 兑换商店按钮（仅特定 NPC）
    if features.exchange then
        btnBar_:AddChild(UI.Button {
            text = "💎 兑换商店",
            fontSize = 12,
            height = 30,
            paddingLeft = 10,
            paddingRight = 10,
            borderRadius = 6,
            backgroundColor = { 60, 180, 160, 220 },
            fontColor = { 10, 20, 20, 255 },
            onClick = function()
                DialogueUI.EndDialogue()
                local ok, ExchangeShopUI = pcall(require, "ui.ExchangeShopUI")
                if ok and ExchangeShopUI then
                    local HUD = require("ui.HUD")
                    HUD.SetCrosshairVisible(false)
                    ExchangeShopUI.Show()
                end
            end,
        })
    end

    -- 跳过对话按钮（始终显示）
    btnBar_:AddChild(UI.Button {
        text = "跳过 ⏭",
        fontSize = 12,
        height = 30,
        paddingLeft = 10,
        paddingRight = 10,
        borderRadius = 6,
        variant = "outline",
        onClick = function()
            DialogueUI.EndDialogue()
        end,
    })
end

-- ============================================================================
-- 开始对话
-- ============================================================================

---@param npcId string
function DialogueUI.StartDialogue(npcId)
    local progress = GameManager.GetQuestProgress()
    local dialogue = QuestData.GetDialogue(npcId, progress)

    if not dialogue or #dialogue == 0 then
        print("[DialogueUI] NPC " .. npcId .. " 无可用对话")
        return false
    end

    currentDialogue_ = dialogue
    currentNpcId_ = npcId
    currentIndex_ = 0
    isActive_ = true

    -- 切换游戏状态
    GameManager.SetState(GameConfig.States.DIALOGUE)
    FirstPersonController.SetMouseAbsolute()

    -- 根据 NPC 构建按钮栏
    rebuildBtnBar(npcId)

    -- 显示对话框
    if dialogueRoot_ then
        dialogueRoot_:Show()
    end

    -- 显示第一句
    DialogueUI.NextLine()

    print("[DialogueUI] 开始与 " .. npcId .. " 对话")
    return true
end

-- ============================================================================
-- 下一句对话
-- ============================================================================

function DialogueUI.NextLine()
    if not isActive_ or not currentDialogue_ then return end

    currentIndex_ = currentIndex_ + 1

    if currentIndex_ > #currentDialogue_ then
        -- 对话结束
        DialogueUI.EndDialogue()
        return
    end

    local line = currentDialogue_[currentIndex_]

    -- 设置说话者
    if speakerLabel_ then
        speakerLabel_:SetText(line.speaker or "")
    end

    -- 准备逐字显示
    fullText_ = line.text or ""
    displayedText_ = ""
    charTimer_ = 0
    isTextComplete_ = false

    -- 隐藏翻页提示
    if hintLabel_ then
        hintLabel_:SetStyle({ fontColor = { 180, 180, 180, 0 } })
    end

    -- 处理物品赠送
    if line.giveItem then
        GameManager.AddItem(line.giveItem)
        local itemInfo = QuestData.GetItemInfo(line.giveItem)
        if itemInfo then
            fullText_ = fullText_ .. "\n\n【获得物品：" .. itemInfo.name .. "】"
        end
    end
end

-- ============================================================================
-- 结束对话
-- ============================================================================

function DialogueUI.EndDialogue()
    isActive_ = false
    currentDialogue_ = nil
    currentIndex_ = 0

    -- 标记已对话
    if currentNpcId_ then
        GameManager.MarkNPCTalked(currentNpcId_)
    end
    currentNpcId_ = nil

    -- 隐藏对话框
    if dialogueRoot_ then
        dialogueRoot_:Hide()
    end

    -- 恢复游戏状态
    GameManager.SetState(GameConfig.States.PLAYING)
    FirstPersonController.SetMouseRelative()

    -- 回调
    if onDialogueEnd_ then
        onDialogueEnd_()
    end

    print("[DialogueUI] 对话结束")
end

-- ============================================================================
-- 每帧更新（逐字显示 + 输入检测）
-- ============================================================================

---@param dt number
function DialogueUI.Update(dt)
    if not isActive_ then return end

    -- 逐字显示
    if not isTextComplete_ then
        charTimer_ = charTimer_ + dt

        -- 计算应显示的字符数（UTF-8安全截取近似：直接用全文）
        local targetLen = math.floor(charTimer_ / charSpeed_)
        -- 简化处理：用字节索引近似（中文3字节/字）
        local fullLen = #fullText_
        local showBytes = math.min(targetLen * 3, fullLen)  -- 近似

        if showBytes >= fullLen then
            displayedText_ = fullText_
            isTextComplete_ = true
            -- 显示翻页提示
            if hintLabel_ then
                hintLabel_:SetStyle({ fontColor = { 180, 180, 180, 140 } })
            end
        else
            -- 避免截断UTF-8字符：找到最近的有效UTF-8字节边界
            local pos = showBytes
            while pos > 0 and pos < fullLen do
                local byte = string.byte(fullText_, pos + 1)
                if byte == nil or byte < 128 or (byte >= 192) then
                    break
                end
                pos = pos - 1
            end
            displayedText_ = string.sub(fullText_, 1, pos)
        end

        if textLabel_ then
            textLabel_:SetText(displayedText_)
        end
    end

    -- 输入检测
    local advance = input:GetKeyPress(KEY_SPACE)
        or input:GetKeyPress(KEY_RETURN)
        or input:GetKeyPress(KEY_F)
        or input:GetMouseButtonPress(MOUSEB_LEFT)

    if advance then
        if isTextComplete_ then
            -- 已显示完毕，下一句
            DialogueUI.NextLine()
        else
            -- 跳过逐字显示，直接显示全文
            displayedText_ = fullText_
            isTextComplete_ = true
            if textLabel_ then
                textLabel_:SetText(displayedText_)
            end
            if hintLabel_ then
                hintLabel_:SetStyle({ fontColor = { 180, 180, 180, 140 } })
            end
        end
    end

    -- ESC 强制结束对话
    if input:GetKeyPress(KEY_ESCAPE) then
        DialogueUI.EndDialogue()
    end
end

-- ============================================================================
-- 查询状态
-- ============================================================================

---@return boolean
function DialogueUI.IsActive()
    return isActive_
end

---@return table
function DialogueUI.GetRoot()
    return dialogueRoot_
end

return DialogueUI
