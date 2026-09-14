package main

type Server struct {
	Port int
}

func NewServer(port int) *Server {
	return &Server{Port: port}
}

func (s *Server) Start() error {
	return nil
}

func main() {
	s := NewServer(8080)
	_ = s.Start()
}
