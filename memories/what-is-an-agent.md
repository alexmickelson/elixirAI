## problem

context is short. After 30 min working on a problem, llms have to reset. 
- Compressing previous conversation doesn't work
  - llms dont know what is important, refactoring compressions are hard
- memory files can be good, but need to be easily viewed/editied by humans
- sandboxing is hard requirement
  - sandbox needs persistent files per agent
  
even background tools need human approvers with fast correction
- plans are helpful, but need to be maintained
- having an llm proactively make too many edits discourages refactoring to clean systems
    - encourages systems designed by chance, not intentional design
- need easy notification system

