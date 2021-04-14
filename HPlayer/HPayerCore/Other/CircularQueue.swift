//
//  HPCircularQueue.swift
//  HPlayer
//
//  Created by hinson on 2020/12/9.
//  Copyright © 2020 tommy. All rights reserved.
//

import Foundation

/// 环形队列
public class HPCircularQueue<Item: HPQueueItem> {
    private var _buffer = ContiguousArray<Item?>()
//    private let semaphore = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private var headIndex = UInt(0) //头部索引
    private var tailIndex = UInt(0) //尾部索引，元素的后面位置
    ///是否可扩张
    private let expanding: Bool
    ///是否能排序
    private let sorted: Bool
    private var destoryed = false
    ///@inline(__always) 始终内联，_count表示HPCircularQueue里的元素个数
    @inline(__always) private var _count: Int { Int(tailIndex &- headIndex) }
    public var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return _count
    }

    public var maxCount: Int
    ///maxCount为2的幂次-1，所以mask为位掩码，用作生成环形index
    private var mask: UInt

    public init(initialCapacity: Int = 256, sorted: Bool = false, expanding: Bool = true) {
        self.expanding = expanding
        self.sorted = sorted
        //容错处理：capacity必须是2的次幂数
        let capacity = initialCapacity.nextPowerOf2()
        //Array 和 ContiguousArray 区别
        //正因为储存策略的不同，特别是在class 或者 @objc，如果不考虑桥接到 NSArray 或者调用 Objective-C，苹果建议我们使用 ContiguousArray，会更有效率。
        _buffer = ContiguousArray<Item?>(repeating: nil, count: capacity)//一开始都是nil
        maxCount = capacity
        mask = UInt(maxCount - 1)//mask为位掩码，用作生成环形index
        assert(_buffer.count == capacity) //这里一定成立啊，需要验证
    }

    ///加入item到queue中，并且如果需要排序的话，会根据Item的position进行排序
    public func push(_ value: Item) {
        condition.lock()
        defer { condition.unlock() }
        guard !destoryed else {  return }
        
        //tailIndex & mask 的结果在[0-mask]之间，超过mask时又回到了0
        _buffer[Int(tailIndex & mask)] = value
        if sorted {
            // 不用sort进行排序，这个比较高效，因为场景是要插入刚放入的元素到有序的数组中，从尾节点向前比对一趟就好，用sort的复杂度是n^2。
            var index = tailIndex
            while index > headIndex {
                //拿到前驱元素
                guard let item = _buffer[Int((index - 1) & mask)] else {
                    assertionFailure("value is nil of index: \((index - 1) & mask) headIndex: \(headIndex), tailIndex: \(tailIndex)")
                    break
                }
                //前驱元素 position 小于 当前存放的元素时，无需排序
                if item.position < _buffer[Int(index & mask)]!.position {
                    break
                }
                //否则交换
                _buffer.swapAt(Int((index - 1) & mask), Int(index & mask))
                index -= 1
            }
        }
        /* &+ 为溢出运算符，超过后会从从头开始取值
         var v1 = UInt8.max //255
         var v2 = v1 &+ 4 //259
         print("v2=",v2) //3
         */
        tailIndex &+= 1 //溢出运算符，超过最大maxCount后tailIndex会从0开始计数
        
        if _count == maxCount { //元素个数等于最大时扩容
            if expanding {
                // No more room left for another append so grow the buffer now.
                _doubleCapacity()
            } else {
                condition.wait() //read packet时的阀值处理（生产者消费者问题）：当外部read线程向queue中添加的item个数==maxCount时，因为创建的是不能扩容的queue，所以用条件锁阻塞掉read线程，让它不要再read往queue中加item了。
            }
        } else {
            // 只有数据了。就signal。因为有可能这是最后的数据了。
            if _count == 1 {
                condition.signal() //现在有数据了，唤醒因没有数据而进行pop操作被卡住的线程
            }
        }
    }

    public func pop(wait: Bool = false, where predicate: ((Item) -> Bool)? = nil) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        if destoryed {
            return nil
        }
        //如果没有元素
        if headIndex == tailIndex {
            if wait {
                condition.wait() //没有元素了，就卡住pop的操作，等待push的操作往里加元素。
                if destoryed || headIndex == tailIndex {
                    return nil
                }
            } else {
                return nil
            }
        }
        
        let index = Int(headIndex & mask)
        guard let item = _buffer[index] else {
            assertionFailure("value is nil of index: \(index) headIndex: \(headIndex), tailIndex: \(tailIndex)")
            return nil
        }
        if let predicate = predicate, !predicate(item) {
            return nil
        } else { //拿到元素，并且满足predicate条件
            headIndex &+= 1
            _buffer[index] = nil
            
            //read packet时的阀值处理（生产者消费者问题）：read线程不断读取packet到queue中超过最大数量限制时会被锁住，所以当pop出item后检查容量是否小于maxCount的一半，符合时就signal()激活对应被锁住的线程。
            if _count == maxCount >> 1 {
                condition.signal()
            }
            return item
        }
    }

    public func search(where predicate: (Item) -> Bool) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        for i in headIndex ..< tailIndex {
            if let item = _buffer[Int(i)] {
                if predicate(item) {
                    headIndex = i
                    return item
                }
            } else {
                assertionFailure("value is nil of index: \(i) headIndex: \(headIndex), tailIndex: \(tailIndex)")
                return nil
            }
        }
        return nil
    }

    ///清空queue
    public func flush() {
        condition.lock()
        defer { condition.unlock() }
        headIndex = 0
        tailIndex = 0
        _buffer.removeAll(keepingCapacity: true)
        _buffer.append(contentsOf: ContiguousArray<Item?>(repeating: nil, count: maxCount))
        condition.broadcast()
    }

    public func shutdown() {
        destoryed = true
        flush()
    }

    private func _doubleCapacity() {
        var newBacking: ContiguousArray<Item?> = []
        let newCapacity = maxCount << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(_buffer.count)")
        assert(newCapacity % 2 == 0)
        newBacking.reserveCapacity(newCapacity)
        let head = Int(headIndex & mask)
        newBacking.append(contentsOf: _buffer[head ..< maxCount])
        if head > 0 {
            newBacking.append(contentsOf: _buffer[0 ..< head])
        }
        let repeatitionCount = newCapacity &- newBacking.count
        newBacking.append(contentsOf: repeatElement(nil, count: repeatitionCount))
        headIndex = 0
        tailIndex = UInt(newBacking.count &- repeatitionCount)
        _buffer = newBacking
        maxCount = newCapacity
        mask = UInt(maxCount - 1)
    }
}

extension FixedWidthInteger {
    
    /* 返回最小的2次幂
     12 -> 16
     ob00001100
     ob00001011
     2的4

     9 -> 16
     ob00001001
     ob00001000
     2的4

     8 -> 8
     ob00001000
     ob00000111
     2的3

     7 -> 8
     ob00000111
     ob00000110
     2的3
     */
    /// Returns the next power of two. 返回最小的2次幂
    @inline(__always) func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
