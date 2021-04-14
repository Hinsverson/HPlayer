//
//  Helper.swift
//  HPlayer
//
//  Created by hinson on 2020/12/14.
//  Copyright © 2020 tommy. All rights reserved.
//

import Foundation

extension Array {
    init(tuple: (Element, Element, Element, Element, Element, Element, Element, Element)) {
        self.init([tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7])
    }

    init(tuple: (Element, Element, Element, Element)) {
        self.init([tuple.0, tuple.1, tuple.2, tuple.3])
    }

    var tuple8: (Element, Element, Element, Element, Element, Element, Element, Element) {
        (self[0], self[1], self[2], self[3], self[4], self[5], self[6], self[7])
    }

    var tuple4: (Element, Element, Element, Element) {
        (self[0], self[1], self[2], self[3])
    }
}

extension CGSize {
    var reverse: CGSize {
        CGSize(width: height, height: width)
    }

    var toPoint: CGPoint {
        CGPoint(x: width, y: height)
    }
}

//MARK: - UI
import UIKit
extension UIScreen {
    static var size: CGSize {
        main.bounds.size
    }
}
extension UIView {
    func image() -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(bounds.size, isOpaque, 0.0)
        defer { UIGraphicsEndImageContext() }
        if let context = UIGraphicsGetCurrentContext() {
            layer.render(in: context)
            let image = UIGraphicsGetImageFromCurrentImageContext()
            return image
        }
        return nil
    }

    public func centerRotate(byDegrees: Double) {
        transform = CGAffineTransform(rotationAngle: CGFloat(Double.pi * byDegrees / 180.0))
    }
}


public typealias UIViewContentMode = UIView.ContentMode

//MARK: - Global
public func runInMainqueue(block: @escaping () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.async(execute: block)
    }
}

//https://juejin.cn/post/6844904018121064456
@propertyWrapper public final class HPObservable<T> {
    public var observer: ((_ oldValue: T, _ newValue: T) -> Void)? {
        didSet {
            observer?(wrappedValue, wrappedValue)
        }
    }
    ///propertyWrapper必须实现wrappedValue属性，外部实际的属性set、get动作发生在这里
    public var wrappedValue: T {
        didSet {
            observer?(oldValue, wrappedValue)
        }
    }

    //通过定义projectedValue属性，属性包装器可以公开更多API。 对projectedValue的类型没有任何限制。
    public var projectedValue: HPObservable { self }

    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }
}
