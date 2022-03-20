class Assessment360Controller < ApplicationController
  before_action :init_data

  include GradesHelper
  include AuthorizationHelper
  include Scoring
  # Added the @instructor to display the instructor name in the home page of the 360 degree assessment
  def action_allowed?
    current_user_has_ta_privileges?
  end


  # Find the list of all students and assignments pertaining to the course.
  # This data is used to compute the instructor assigned grade and peer review scores.
  # There are many nuances about how to collect these scores. See our design document for more deails
  # http://wiki.expertiza.ncsu.edu/index.php/CSC/ECE_517_Fall_2018_E1871_Grade_Summary_By_Student
  def course_student_grade_summary
    @topics = {}
    @assignment_grades = {}
    @peer_review_scores = {}
    @final_grades = {}
    @course_participants.each do |cp|
      @topics[cp.id] = {}
      @assignment_grades[cp.id] = {}
      @peer_review_scores[cp.id] = {}
      @final_grades[cp.id] = 0
      @assignments.each do |assignment|
        user_id = cp.user_id
        assignment_id = assignment.id
        next if assignment.participants.find_by(user_id: user_id).nil? # break out of the loop if there are no participants in the assignment
        next if TeamsUser.team_id(assignment_id, user_id).nil? # break out of the loop if the participant has no team

        assignment_grade_summary(cp, assignment_id) # pull information about the student's grades for particular assignment
        peer_review_score = find_peer_review_score(user_id, assignment_id)

        next if peer_review_score.nil? # Skip if there are no peers
        next if peer_review_score[:review].nil? # Skip if there are no reviews done by peer
        next if peer_review_score[:review][:scores].nil? # Skip if there are no reviews scores assigned by peer
        next if peer_review_score[:review][:scores][:avg].nil? # Skip if there are is no peer review average score

        @peer_review_scores[cp.id][assignment_id] = peer_review_score[:review][:scores][:avg].round(2)
      end
    end
  end

  def assignment_grade_summary(cp, assignment_id)
    user_id = cp.user_id
    # topic exists if a team signed up for a topic, which can be found via the user and the assignment
    topic_id = SignedUpTeam.topic_id(assignment_id, user_id)
    @topics[cp.id][assignment_id] = SignUpTopic.find_by(id: topic_id)
    # instructor grade is stored in the team model, which is found by finding the user's team for the assignment
    team_id = TeamsUser.team_id(assignment_id, user_id)
    team = Team.find(team_id)
    return if team[:grade_for_submission].nil?
    @assignment_grades[cp.id][assignment_id] = team[:grade_for_submission]

    @final_grades[cp.id] += @assignment_grades[cp.id][assignment_id]
  end

  # The peer review score is taken from the questions for the assignment
  def find_peer_review_score(user_id, assignment_id)
    participant = AssignmentParticipant.find_by(user_id: user_id, parent_id: assignment_id)
    assignment = participant.assignment
    questions = retrieve_questions assignment.questionnaires, assignment_id
    participant_scores(participant, questions)
  end

  def format_topic(topic)
    topic.nil? ? '–' : topic.format_for_display
  end

  def format_score(score)
    score.nil? ? '–' : score
  end

  def format_percentage(score)
    score.nil? ? '–' : score.to_s + '%'
  end

  helper_method :format_score
  helper_method :format_topic
  helper_method :format_percentage

  def index
    calc_teammate_count

    # Calculate avg review score
    @meta_review = reviews_for_type('meta')
    @meta_review[:aggregate_score] = calc_aggregate_score(@meta_review)
    @meta_review[:class_avg] = calc_class_avg_score(@meta_review)
    @meta_review[:aggregate_score_class_avg] = calc_aggregate_score_class_avg(@meta_review)

    @teammate_review = reviews_for_type('teammate')
    @teammate_review[:aggregate_score] = calc_aggregate_score(@teammate_review)
    @teammate_review[:class_avg] = calc_class_avg_score(@teammate_review)
    @teammate_review[:aggregate_score_class_avg] = calc_aggregate_score_class_avg(@teammate_review)
    course_student_grade_summary
    @peer_review_scores[:class_avg] = calc_class_avg_score(@peer_review_scores)
    @assignment_grades[:class_avg] = calc_class_avg_score(@assignment_grades)
  end

  private
    def init_data
      @course = Course.find(params[:course_id])

      # Load participants along with the assignments(eager loading)
      # TODO: What does calibrate does?
      # Reject assignments with empty participants
      @assignments = @course.assignments.includes([:participants]).reject(&:is_calibrated).reject { |a| a.participants.empty? }

      @course_participants = @course.get_participants
      insure_existence_of(@course_participants, @course)
    end

    # compute review score based on the type of all assignments for all students and
    # return a map with the review score with cp_id and assignment_id
    # as key. example return object structure
    # review = {
    #   STUDENT_1_ID: {
    #     ASSIGNMENT_1_ID: 95,
    #     ASSIGNMENT_2_ID: 70,
    #     ASSIGNMENT_3_ID: 90
    #   },
    #   STUDENT_2_ID: {
    #     ASSIGNMENT_2_ID: 80,
    #     ASSIGNMENT_4_ID: 70
    #   }
    # }
    # accessing the score from the output object,
    # review[STUDENT_1_ID][ASSIGNMENT_1_ID] = 95
    def reviews_for_type(type)
      reviews_variable = type + '_reviews'
      review = {}

      # Create a map with user_id and assignment_id as key and reviews as value
      reviews_by_user_id_and_assignment = reviews_by_user_id_and_assignment(reviews_variable)

      @course_participants.each do |cp|
        review[cp.id] = {}
        @assignments.each do |assignment|
          # skip if the student is not participated in any assignment
          next if reviews_by_user_id_and_assignment[cp.user_id].nil?

          # skip if the student is not participated in the current assignment
          next if reviews_by_user_id_and_assignment[cp.user_id][assignment.id].nil?

          reviews = reviews_by_user_id_and_assignment[cp.user_id][assignment.id]
          score = calc_avg_score(reviews)

          # Don't set score as nil because, this will create a entry in the review map with cp.id and assignment.id as
          # key and nil as value. This will make it easy to count the number of assignments attempted while calculating
          # class average and aggregate score
          review[cp.id][assignment.id] = score unless score.nil?
        end
      end
      return review
    end

    def insure_existence_of(course_participants, course)
      if course_participants.empty?
        flash[:error] = "There is no course participant in course #{course.name}"
        redirect_to(:back)
      end
    end

    def reviews_by_user_id_and_assignment(reviews_variable)
      reviews = {}
      @assignments.each do |assignment|
        assignment.participants.all.each do |assignment_participant|
          reviews[assignment_participant.user_id] = {} unless reviews.key?(assignment_participant.user_id)
          assignment_reviews = assignment_participant.public_send(reviews_variable) if assignment_participant.respond_to? reviews_variable
          reviews[assignment_participant.user_id][assignment.id] = assignment_reviews
        end
      end
      return reviews
    end

    def calc_avg_score(reviews)
      # If a student has not taken an assignment or if they have not received any grade for the same,
      # assign it as nil(not returning anything). This helps in easier calculation of overall grade
      grades = 0
      # Check if they person has gotten any review for the assignment
      if reviews.count > 0
        reviews.each { |review| grades += review.average_score.to_i }
        return (grades * 1.0 / reviews.count).round
      end
    end

    # TODO: https://github.com/sak007/expertiza/issues/2
    def calc_teammate_count
      @teamed_count = {}
      @course_participants.each do |cp|
        students_teamed = StudentTask.teamed_students(cp.user)
        @teamed_count[cp.id] = students_teamed[@course.id].try(:size).to_i
      end
    end

    # Calculate average review score of all the assignment completed by the student.
    # Return object structure,
    # aggregate_scores = {
    #   STUDENT_ID_1: 100,
    #   STUDENT_ID_2: 98
    # }
    def calc_aggregate_score(review)
      aggregate_scores = {}
      review.each do |cp_id, assignment_review_scores_map|
        aggregate_scores[cp_id] = (assignment_review_scores_map.inject(0) {|sum , (k,v)| sum += v } * 1.0 / assignment_review_scores_map.size).round unless assignment_review_scores_map.empty?
      end
      return aggregate_scores
    end

    # Calculate average review score of all students for each assignment
    # Return object structure,
    # assignment_review_scores = {
    #   ASSIGNMENT_1_ID: 98,
    #   ASSIGNMENT_2_ID: 97
    # }
    def calc_class_avg_score(review)
      assignment_review_scores = {}
      total_review_scores = {}
      review_counts = {}
      review.each do |cp_id, assignment_review_scores_map|
        assignment_review_scores_map.each do |assignment_id, score|
          total_review_scores[assignment_id] = 0 unless total_review_scores.key?(assignment_id)
          review_counts[assignment_id] = 0 unless review_counts.key?(assignment_id)
          total_review_scores[assignment_id] += score
          review_counts[assignment_id] += 1
        end
      end

      @assignments.each do |assignment|
        assignment_review_scores[assignment.id] = (total_review_scores[assignment.id] * 1.0 / review_counts[assignment.id]).round(2) if review_counts.key?(assignment.id)
      end

      return assignment_review_scores
    end

    # Calculate average aggregate review score of all students
    def calc_aggregate_score_class_avg(review)
      return (review[:aggregate_score].values.sum * 1.0 / review[:aggregate_score].size).round unless review[:aggregate_score].empty?
    end
end
