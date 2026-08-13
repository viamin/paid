interface Greeter {
  greet(): string;
}

class Person extends BaseEntity {
  private name: string;

  constructor(name: string) {
    super();
    this.name = name;
  }

  greet(): string {
    return `Hello, ${this.name}`;
  }
}

class SimpleWorker {
  perform(): void {
    console.log("working");
  }
}

function createPerson(name: string, age: number): Person {
  return new Person(name);
}

type StringMap = Record<string, string>;
