#import "Basic";

#load "some.jai";

CONST_NUMBER :: 10;

Gender :: enum {
    MALE :: 1;
    FEMALE :: 2;
}

// cache: Table(int, string);

Person :: struct {
    name: string;
    age: int;
}

john: Person;

Test :: struct (Type_Of_A: Type) {
    a: Type_Of_A;
}

x: Test(int);

test :: (name := "test", numba: int, st: Test) {
    
}

main :: () {
    y := x;

    print_some :: (y: string) {
        p := y;
    }    

    hj := Gender.MALE;

    print_some("Test 2");

    print("Hello World %\n", KOOP);
    print_some("test");
}

