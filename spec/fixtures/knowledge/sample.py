class Animal:
    def __init__(self, name: str):
        self.name = name

    def speak(self) -> str:
        raise NotImplementedError


class Dog(Animal):
    def speak(self) -> str:
        return f"{self.name} says Woof!"

    def fetch(self, item: str) -> str:
        return f"Fetching {item}"


def create_animal(name: str, kind: str) -> Animal:
    if kind == "dog":
        return Dog(name)
    return Animal(name)
