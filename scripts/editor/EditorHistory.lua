-- ============================================================================
-- EditorHistory.lua — 撤销/重做命令栈
-- 记录编辑器操作，支持 Ctrl+Z 撤销、Ctrl+Y 重做
-- ============================================================================

local UI = require("urhox-libs/UI")

local EditorHistory = {}

local MAX_HISTORY = 30

-- 命令栈
local undoStack_ = {}   -- { {type, undo(), redo(), desc}, ... }
local redoStack_ = {}

-- ============================================================================
-- 核心 API
-- ============================================================================

--- 记录一个可撤销的操作
---@param cmd table { type: string, desc: string, undo: function, redo: function }
function EditorHistory.Record(cmd)
    table.insert(undoStack_, cmd)
    -- 新操作清空重做栈
    redoStack_ = {}
    -- 限制历史长度
    if #undoStack_ > MAX_HISTORY then
        table.remove(undoStack_, 1)
    end
    print("[History] 记录: " .. (cmd.desc or cmd.type))
end

--- 撤销上一步操作
---@return boolean 是否成功撤销
function EditorHistory.Undo()
    if #undoStack_ == 0 then
        UI.Toast.Show("没有可撤销的操作", { variant = "warning", duration = 1.5 })
        return false
    end

    local cmd = table.remove(undoStack_)
    local ok, err = pcall(cmd.undo)
    if ok then
        table.insert(redoStack_, cmd)
        UI.Toast.Show("撤销: " .. (cmd.desc or ""), { variant = "info", duration = 1.2 })
        print("[History] 撤销: " .. (cmd.desc or cmd.type))
        return true
    else
        print("[History] 撤销失败: " .. tostring(err))
        UI.Toast.Show("撤销失败", { variant = "error", duration = 2 })
        return false
    end
end

--- 重做上一步撤销的操作
---@return boolean 是否成功重做
function EditorHistory.Redo()
    if #redoStack_ == 0 then
        UI.Toast.Show("没有可重做的操作", { variant = "warning", duration = 1.5 })
        return false
    end

    local cmd = table.remove(redoStack_)
    local ok, err = pcall(cmd.redo)
    if ok then
        table.insert(undoStack_, cmd)
        UI.Toast.Show("重做: " .. (cmd.desc or ""), { variant = "info", duration = 1.2 })
        print("[History] 重做: " .. (cmd.desc or cmd.type))
        return true
    else
        print("[History] 重做失败: " .. tostring(err))
        UI.Toast.Show("重做失败", { variant = "error", duration = 2 })
        return false
    end
end

--- 清空所有历史
function EditorHistory.Clear()
    undoStack_ = {}
    redoStack_ = {}
end

--- 获取历史状态
---@return number undoCount
---@return number redoCount
function EditorHistory.GetCounts()
    return #undoStack_, #redoStack_
end

--- 是否可撤销
---@return boolean
function EditorHistory.CanUndo()
    return #undoStack_ > 0
end

--- 是否可重做
---@return boolean
function EditorHistory.CanRedo()
    return #redoStack_ > 0
end

-- ============================================================================
-- 便捷命令创建器
-- ============================================================================

--- 创建变换命令
---@param node Node
---@param oldPos Vector3
---@param oldRot Quaternion
---@param oldScale Vector3
---@param newPos Vector3
---@param newRot Quaternion
---@param newScale Vector3
---@param refreshFn function|nil
---@return table cmd
function EditorHistory.MakeTransformCmd(node, oldPos, oldRot, oldScale, newPos, newRot, newScale, refreshFn)
    return {
        type = "transform",
        desc = "变换 " .. (node.name or "节点"),
        undo = function()
            node.position = oldPos
            node.rotation = oldRot
            node.scale = oldScale
            if refreshFn then refreshFn() end
        end,
        redo = function()
            node.position = newPos
            node.rotation = newRot
            node.scale = newScale
            if refreshFn then refreshFn() end
        end,
    }
end

--- 创建材质颜色命令
---@param desc string
---@param applyFn function(color) 应用函数
---@param oldVal any
---@param newVal any
---@return table cmd
function EditorHistory.MakePropertyCmd(desc, applyFn, oldVal, newVal)
    return {
        type = "property",
        desc = desc,
        undo = function() applyFn(oldVal) end,
        redo = function() applyFn(newVal) end,
    }
end

return EditorHistory
