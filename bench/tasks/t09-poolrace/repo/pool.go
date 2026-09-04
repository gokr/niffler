package pool

import "sync"

// Run doubles each job on one of `workers` goroutines and returns the sum
// of all results.
func Run(jobs []int, workers int) int {
	if workers < 1 {
		workers = 1
	}
	if len(jobs) == 0 {
		return 0
	}
	total := 0
	ch := make(chan int)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range ch {
				total += j * 2 // BUG: unsynchronized shared counter
			}
		}()
	}
	for _, j := range jobs {
		ch <- j
	}
	close(ch)
	wg.Wait()
	return total
}
