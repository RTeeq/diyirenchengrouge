-- ============================================================================
-- SaveSystem.lua — 多槽位本地存档系统
-- 最多 4 个存档槽位，每个存档独立文件
-- 注意: WASM 平台刷新页面后存档会丢失
-- ============================================================================

local GameManager = require("core.GameManager")

local SaveSystem = {}

local MAX_SLOTS = 4
local SAVE_DIR = "saves"
local activeSlot_ = nil  -- 当前激活的存档槽位 (1~4)

-- ============================================================================
-- 内部工具
-- ============================================================================

---@param slot number
---@return string
local function slotFile(slot)
    return SAVE_DIR .. "/slot" .. slot .. ".json"
end

local function ensureDir()
    if not fileSystem:DirExists(SAVE_DIR) then
        fileSystem:CreateDir(SAVE_DIR)
    end
end

-- ============================================================================
-- 槽位管理
-- ============================================================================

---@return number 最大槽位数
function SaveSystem.GetMaxSlots() return MAX_SLOTS end

---@param slot number
function SaveSystem.SetActiveSlot(slot)
    activeSlot_ = slot
    print("[SaveSystem] 激活槽位: " .. slot)
end

---@return number|nil
function SaveSystem.GetActiveSlot()
    return activeSlot_
end

-- ============================================================================
-- 保存（写入当前激活槽位）
-- ============================================================================

---@return boolean
function SaveSystem.Save()
    if not activeSlot_ then
        print("[SaveSystem] 无激活槽位，跳过保存")
        return false
    end
    ensureDir()

    local saveData = GameManager.GetSaveData()
    saveData.timestamp = os.time()

    local ok, jsonStr = pcall(cjson.encode, saveData)
    if not ok then
        print("[SaveSystem] JSON编码失败: " .. tostring(jsonStr))
        return false
    end

    local file = File(slotFile(activeSlot_), FILE_WRITE)
    if not file:IsOpen() then
        print("[SaveSystem] 无法打开存档文件写入")
        return false
    end

    file:WriteString(jsonStr)
    file:Close()
    print("[SaveSystem] 槽位 " .. activeSlot_ .. " 存档成功")
    return true
end

-- ============================================================================
-- 读取指定槽位
-- ============================================================================

---@param slot number
---@return boolean
function SaveSystem.Load(slot)
    slot = slot or activeSlot_
    if not slot then return false end

    local path = slotFile(slot)
    if not fileSystem:FileExists(path) then
        print("[SaveSystem] 槽位 " .. slot .. " 存档不存在")
        return false
    end

    local file = File(path, FILE_READ)
    if not file:IsOpen() then
        print("[SaveSystem] 无法打开存档文件读取")
        return false
    end

    local jsonStr = file:ReadString()
    file:Close()

    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok then
        print("[SaveSystem] JSON解码失败: " .. tostring(data))
        return false
    end

    activeSlot_ = slot
    GameManager.LoadSaveData(data)
    print("[SaveSystem] 槽位 " .. slot .. " 读档成功")
    return true
end

-- ============================================================================
-- 删除指定槽位
-- ============================================================================

---@param slot number
---@return boolean
function SaveSystem.Delete(slot)
    slot = slot or activeSlot_
    if not slot then return false end

    local path = slotFile(slot)
    if fileSystem:FileExists(path) then
        local file = File(path, FILE_WRITE)
        if file:IsOpen() then
            file:WriteString("")
            file:Close()
        end
        print("[SaveSystem] 槽位 " .. slot .. " 存档已清除")
        return true
    end
    return false
end

-- ============================================================================
-- 查询槽位信息（用于存档列表 UI）
-- ============================================================================

--- 读取槽位摘要（不加载到游戏）
---@param slot number
---@return table|nil { gold, crystal, timestamp, level, ... }
function SaveSystem.GetSlotInfo(slot)
    local path = slotFile(slot)
    if not fileSystem:FileExists(path) then
        return nil
    end

    local file = File(path, FILE_READ)
    if not file:IsOpen() then return nil end

    local jsonStr = file:ReadString()
    file:Close()

    if not jsonStr or jsonStr == "" then return nil end

    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok then return nil end

    return data
end

--- 获取所有槽位摘要
---@return table[] { [1]...[4] = info|nil }
function SaveSystem.GetAllSlotInfos()
    local infos = {}
    for i = 1, MAX_SLOTS do
        infos[i] = SaveSystem.GetSlotInfo(i)
    end
    return infos
end

--- 检查指定槽位是否有存档
---@param slot number
---@return boolean
function SaveSystem.HasSave(slot)
    if slot then
        return SaveSystem.GetSlotInfo(slot) ~= nil
    end
    -- 兼容旧调用：检查任意槽位
    for i = 1, MAX_SLOTS do
        if SaveSystem.GetSlotInfo(i) then return true end
    end
    return false
end

return SaveSystem
