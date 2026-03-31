#!/usr/bin/env python3

def sing_99_beers():
    for i in range(99, 0, -1):
        bottle = "bottles" if i > 1 else "bottle"
        next_bottle = "bottles" if i - 1 != 1 else "bottle"
        next_num = i - 1 if i > 1 else "no more"
        
        print(f"{i} {bottle} of beer on the wall,")
        print(f"{i} {bottle} of beer,")
        print("Take one down, pass it around,")
        print(f"{next_num} {next_bottle if i > 1 else 'bottles'} of beer on the wall!\n")
    
    print("No more bottles of beer on the wall,")
    print("No more bottles of beer,")
    print("Go to the store and buy some more,")
    print("99 bottles of beer on the wall!")

if __name__ == "__main__":
    sing_99_beers()
