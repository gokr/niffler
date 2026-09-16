#include <string>

class Widget {
public:
    int size() const { return size_; }
    void grow(int by) { size_ += by; }

private:
    int size_ = 0;
};

int measure(const Widget& w) {
    return w.size();
}
