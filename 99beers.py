def sing(bottles):
    for i in range(bottles, 0, -1):
        b = "bottle" if i == 1 else "bottles"
        next_b = "bottle" if i - 1 == 1 else "bottles"
        next_num = i - 1 if i > 1 else "no more"
        
        print(f"{i} {b} of beer on the wall, {i} {b} of beer.")
        print(f"Take one down and pass it around, {next_num} {next_b} of beer on the wall.")
        print()
    
    print("No more bottles of beer on the wall, no more bottles of beer.")
    print("Go to the store and buy some more, 99 bottles of beer on the wall.")

sing(99)
