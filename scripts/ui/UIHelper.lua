-- ============================================================================
-- UIHelper.lua — UI 工具函数
-- 解决 RemoveAllChildren 不释放 YGNode 导致 "View exceeds maximum limit" 的问题
-- ============================================================================

local UIHelper = {}

--- 安全清除容器的所有子节点（先 Destroy 再清除，释放 YGNode）
--- Widget:RemoveAllChildren() 只解除引用但不调用 YGNodeFree，
--- 导致旧节点泄漏，累积超过引擎限制（约 1000 个 View）。
---@param container any UI Widget 容器
function UIHelper.DestroyChildren(container)
    if not container then return end
    local children = container.children
    if not children or #children == 0 then return end
    -- 先复制快照，因为 Destroy 会修改 children 数组
    local snapshot = {}
    for i = 1, #children do
        snapshot[i] = children[i]
    end
    -- 逆序销毁所有子节点（Destroy 会递归释放子树 + YGNodeFree）
    for i = #snapshot, 1, -1 do
        local child = snapshot[i]
        if child and child.Destroy then
            child:Destroy()
        end
    end
end

return UIHelper
