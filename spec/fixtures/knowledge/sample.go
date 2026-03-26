package sample

type Animal interface {
	Speak() string
}

type Dog struct {
	Name string
	Age  int
}

func (d *Dog) Speak() string {
	return d.Name + " says Woof!"
}

func NewDog(name string, age int) *Dog {
	return &Dog{Name: name, Age: age}
}
