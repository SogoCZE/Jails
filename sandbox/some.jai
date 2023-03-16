#load "third.jai";

test :: () {

}

test2 :: () {
    test();
}

print_some :: (x: int) {
    test2();
}