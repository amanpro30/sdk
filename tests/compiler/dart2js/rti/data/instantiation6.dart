// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*kernel.element: f:direct,explicit=[f.T]*/
/*!kernel.element: f:deps=[method],direct,explicit=[f.T],needsArgs,needsInst=[<method.S>]*/
bool f<T>(T a) => a is T;

typedef bool F<R>(R a);

/*!kernel.element: method:indirect,needsArgs*/
method<S>() {
  F<S> c;

  return () {
    c = f;
    return c;
  };
}

main() {
  method();
}
