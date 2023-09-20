---
layout: post
title: "Pass Go Structs and Arrays as Pointers, Everything Else as Values"
subtitle: "Don't Overthink It"
date: 2023-09-20
head-extra: tracking.html
---

At work, we recently started a discussion on when to pass function arguments as pointers (by reference) and when to pass by value. A related (but subtly different) question is whether to use pointer [receivers](https://go.dev/ref/spec#Method_declarations) or value receivers. Unfortunately, Go's documentation and standard library aren't clear on this point, and Google's Go styleguide has [some guidance](https://google.github.io/styleguide/go/decisions#pass-values), but it's a bit too handwavy.

Let's start with Google's styleguide.

> Do not pass pointers as function arguments just to save a few bytes. If a function reads its argument x only as *x throughout, then the argument shouldn’t be a pointer. Common instances of this include passing a pointer to a string (*string) or a pointer to an interface value (*io.Reader). In both cases, the value itself is a fixed size and can be passed directly.

> This advice does not apply to large structs, or even small structs that may increase in size. In particular, protocol buffer messages should generally be handled by pointer rather than by value. The pointer type satisfies the proto.Message interface (accepted by proto.Marshal, protocmp.Transform, etc.), and protocol buffer messages can be quite large and often grow larger over time.

Okay, so scalar value types like `string`, and interfaces, are clear - pass by value. Arrays are also clear - copying them is expensive, so pass them by reference. Structs ... less so. Large (whatever that means) or growable structs should be passed by reference, but small(?) structs should be passed by value. What's the cutoff, is it a question of performance?

> Note: There is a lot of misinformation about whether passing a value or a pointer to a function can affect performance. The compiler can choose to pass pointers to values on the stack as well as copying values on the stack, but these considerations should not outweigh the readability and correctness of the code in most circumstances. When the performance does matter, it is important to profile both approaches with a realistic benchmark before deciding that one approach outperforms the other.

Okay, so stuff like stack vs heap allocation, and copying, matters from a performance perspective. We'll get back to this later.

What about the standard library? Here, I'm most familiar with the [net](https://pkg.go.dev/net), [net/http](https://pkg.go.dev/net/http) and [crypto/tls](https://pkg.go.dev/crypto/tls) packages. In these packages, most of the value types are things like `net.IP` or `http.Header` which aren't structs, but rather slices or maps or scalars of some sort, and these are always passed as values (not pointers). The struct types are mostly stateful mutable things like `net.TCPConn` or `http.Server`, and often they're wrapped by interfaces like `net.Conn`. The concrete structs are always passed by pointer, and the interfaces are always passed by value.

Taken together with the Google styleguide, we arrive at the below candidate heuristics:

---

1. Types that are not structs or arrays, i.e. scalars, slices, maps, interfaces should be passed by value.
2. Arrays and big or mutable structs should be passed by pointer.

---

Still, I'm left wondering about the elusive "small" structs. Thankfully, my hunt for small structs bags a nice `Animal` in the [example](https://pkg.go.dev/encoding/json#example-Unmarshal) for `json.Unmarshal`. Presumably, if the example were an animal decoder function rather than just a `main` function, it might look like this:


```go
type Animal struct {
	Name  string
	Order string
}

func decodeAnimal(jsonBlob []byte) Animal {
	var animal Animal
	err := json.Unmarshal(jsonBlob, &animal)
	if err != nil {
		panic(err)
	}
	return animal
}
```

I've definitely seen functions like this in use at work, and I see a similar pattern used in the Go [SQL tutorial](https://go.dev/doc/tutorial/database-access). `Animal` is a small struct and returning it as a value allows for stack allocation (maybe?). We'll get back to this later.

So at this point, our candidate heuristics are:

---

1. Types that are not arrays or structs, i.e. scalars, slices, maps, interfaces should be passed by value.
2. Arrays and big or mutable structs should be passed by pointer
3. Small structs should be passed by value.

---

But wait, there's more! When talking about the closely related method receivers, the Google styleguide provides several recommendations on when to use pointer receivers, including:

> There are cases where you must use a pointer value. In other cases, pick pointers for large types or as future-proofing if you don’t have a good sense of how the code will grow, and use values for simple plain old data

> If the method needs to mutate the receiver, the receiver must be a pointer.

> If the receiver is a struct containing fields that cannot safely be copied, use a pointer receiver. Common examples are sync.Mutex and other synchronization types.

Okay, cool, so "small" structs should be treated as values, unless they need to be mutated, or they contain fields that can't be safely copied, or they may eventually evolve into something that meets one of the above criteria. At this point, it seems simpler to me to just pass all structs as references, what rationale is there for not doing this?

According to the Google styleguide

> If the receiver is a “small” array or struct that is naturally a value type with no mutable fields and no pointers, a value receiver is usually the right choice.

Here they give the example of `time.Time`, which is explicitly defined as an immutable type with mutators that return new `time.Time` instances. Another good example of such a type is Shopspring's [decimal](https://github.com/shopspring/decimal) type. It seems to me here that the defining characteristic of these types is not that they're small, but rather that their APIs have been designed to hide their fields from consumers and instead expose mutators that return new values. In essence, these feel a lot like built-in value types such as `string`, `int`, etc, and if Go were a more extensible language these might actually behave just like those types. I can get on board with this.

> For methods that will call or run concurrently with other functions that modify the receiver, use a value if those modifications should not be visible to your method; otherwise use a pointer.

This sounds plausible on in principle, but for me, it comes up very rarely in practice. Also, the devil is in the details. In the one specific case I can think of, the type in question was in fact a slice. Passing a slice by value doesn't cause the underlying array to be copied, so I had to explicitly copy it before passing it along. Even if I had wrapped the slice in a struct as shown below, passing the struct by value wouldn't have helped because both structs would still have been referring to the same underlying array.

```go
type thing struct {
	s []otherThing{}
}
```

So here's another rub - *passing a struct by value doesn't actually guarantee that you won't have shared state*, if the fields on the struct are themselves pointers or pointer-like things (e.g. maps and slices). If you need to make sure you have a copy, you should really explicitly make a deep copy yourself. So yeah, this recommendation doesn't hold water.

> If the receiver is a “large” struct or array, a pointer receiver may be more efficient.

The corrolary to this is that for "small" structs, passing by value may be more efficient, presumably because small structs can be stack allocated when passed by value. In practice though, this isn't the case, both because a) Go's escape analysis is smart enough to stack allocate even pointer variables in some cases and b) interacting with APIs that take `interface{}` parameters like `json.Unmarshal()` and `fmt.Println()` causes even small struct values to end up on the heap.

We can explore this using `go build -gcflags "-m"`. Let's walk through an example.

First, let's take some code that does the "wrong" thing and passes a small struct by pointer.

{% highlight go linenos %}
package alloc

type thing struct {
	A string
	B int
}

func doStuff(t *thing) {
	// do something with t
}

func loadAndDoStuff() {
	t := &thing{}
	t.A = "hello"
	t.B = 42
	doStuff(t)
}
{% endhighlight %}

Compiling with escape analysis we see that `&thing{}` does not escape and will be stack allocated.

```
# alloc
./alloc.go:8:6: can inline doStuff
./alloc.go:12:6: can inline loadAndDoStuff
./alloc.go:16:9: inlining call to doStuff
./alloc.go:8:14: t does not escape
./alloc.go:13:7: &thing{} does not escape
```

Now, let's do the "right" thing by passing `thing{}` as a value, but let's also interact with `json.Marshal()` and `fmt.Println()`.

{% highlight go linenos %}
package alloc

import (
	"encoding/json"
	"fmt"
)

type thing struct {
	A string
	B int
}

func doStuff(t thing) {
	fmt.Println(t)
}

func loadAndDoStuff() {
	var t thing
	err := json.Unmarshal([]byte(`{"A":"hello","B":42}`), &t)
	if err != nil {
		panic(err)
	}
	doStuff(t)
}
{% endhighlight %}

Escape analysis now shows that interacting with those commonly used functions causes our struct to escape to the heap. So, we have the worst of both worlds - no stack allocation, but we still end up copying `thing` when calling `doStuff()`.

```
./alloc.go:13:6: can inline doStuff
./alloc.go:14:13: inlining call to fmt.Println
./alloc.go:23:9: inlining call to doStuff
./alloc.go:23:9: inlining call to fmt.Println
./alloc.go:13:14: leaking param: t
./alloc.go:14:13: ... argument does not escape
./alloc.go:14:14: t escapes to heap
./alloc.go:18:6: moved to heap: t
./alloc.go:19:31: ([]byte)(`{"A":"hello","B":42}`) escapes to heap
./alloc.go:23:9: ... argument does not escape
./alloc.go:23:9: t escapes to heap
```

So where does this leave us? I suggest a fairly simple set of heuristics that applies to both function parameters as well as method receivers. As always, there'll be edge cases where these don't work, but for most cases most of the time, these are make a good baseline.

---

1. **Types that are not structs or arrays should be passed by value.**

2. **Struct types that don't export their members and are clearly built as immutable value types, like `time.Time`, should be passed by value. Note that these types are relatively rare, and are even rarer to be defined by you.**

3. **Arrays and all other struct types should be passed by pointer, whether small, large, stateful, or whatever.**

4. **If you're passing data that could be mutated by a concurrent process and its important to you for that data not to be mutated, explicitly make a copy of it before passing it along. Be aware that you can't just rely on passing the data by value since that does not create a deep copy.**

---

I've personally followed basically these heuristics for years, and they line up well with lots of the Go standard library, but it's nice to have some reasoned justification for them rather than just my intuition. Plus, in addition to working well in a lot of cases, I appreciate these heuristics for their simplicity--they leave little room for ad-hoc judgement calls and free up mental bandwidth for more difficult problems.