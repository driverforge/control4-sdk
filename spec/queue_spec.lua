local Queue = require "queue"

describe('Queue', function()
    describe('push', function()
        it('adds the item in the correct place', function()
            local queue = Queue.new()

            Queue.push(queue, "First")
            Queue.push(queue, "Second")
            Queue.push(queue, "Third")

            assert.equals(table.concat(queue, ","), "First,Second,Third")
        end)
    end)

    describe('pop', function()
        it('removes them in the correct order', function()
            local queue = Queue.new()

            Queue.push(queue, "First")
            Queue.push(queue, "Second")
            Queue.push(queue, "Third")

            assert.equals(Queue.pop(queue), "First")
            assert.equals(Queue.pop(queue), "Second")
            assert.equals(Queue.pop(queue), "Third")
        end)

        context('when the queue is empty', function()
            it('raises an error', function()
                local queue = Queue.new()

                assert.has_error(function() Queue.pop(queue) end, "queue is empty")
            end)
        end)
    end)

    describe('length', function()
        it('has the correct length', function()
            local queue = Queue.new()

            Queue.push(queue, "First")
            Queue.push(queue, "Second")
            Queue.push(queue, "Third")

            assert.equals(Queue.length(queue), 3)
        end)

        it('has the correct length after pops', function()
            local queue = Queue.new()

            Queue.push(queue, "First")
            Queue.push(queue, "Second")
            Queue.push(queue, "Third")
            Queue.pop(queue)

            assert.equals(Queue.length(queue), 2)
        end)
    end)
end)
