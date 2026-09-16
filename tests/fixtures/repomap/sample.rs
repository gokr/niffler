struct Counter {
    n: u32,
}

impl Counter {
    fn bump(&mut self) {
        self.n += 1;
    }
}

fn make_counter() -> Counter {
    Counter { n: 0 }
}
