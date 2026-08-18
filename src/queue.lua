local Queue = (function()
    local queue = {}

    function queue.new()
        return { first = 1, last = 0 }
    end

    function queue.push(target, value)
        local last = target.last + 1
        target.last = last
        target[last] = value
    end

    function queue.pop(target)
        local first = target.first
        if first > target.last then
            error("queue is empty")
        end
        local value = target[first]
        target[first] = nil        -- to allow garbage collection
        target.first = first + 1
        return value
    end

    function queue.length(target)
        return target.last - target.first + 1
    end

    return queue
end)()

return Queue
